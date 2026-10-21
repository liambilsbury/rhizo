#include "hd_pb.h"

#include <string.h>

// field numbers of the Perfetto trace proto
enum {
  F_TIMESTAMP = 8, F_CLOCK_ID = 58, F_TRACK_EVENT = 11, F_TRACK_DESCRIPTOR = 60,
  F_TD_UUID = 1, F_TD_NAME = 2, F_TD_PROCESS = 3, F_TD_THREAD = 4, F_TD_PARENT = 5,
  F_TD_COUNTER = 8,
  F_PD_PID = 1, F_PD_NAME = 6,
  F_THD_PID = 1, F_THD_TID = 2, F_THD_NAME = 5,
  F_TE_DEBUG = 4, F_TE_TYPE = 9, F_TE_UUID = 11, F_TE_NAME = 23, F_TE_COUNTER = 30,
  F_DA_NAME = 10, F_DA_INT = 4,
  TYPE_SLICE_BEGIN = 1, TYPE_SLICE_END = 2, TYPE_COUNTER = 4,
  CLOCK_BOOTTIME = 6,
};

#define WT_VARINT 0
#define WT_LEN 2

// append a byte
static void put_byte(struct hd_buf* b, uint8_t v) {
  if (b->len >= b->cap) {
    b->overflow = true;
    return;
  }
  b->data[b->len++] = v;
}

// append a varint
static void put_varint(struct hd_buf* b, uint64_t v) {
  while (v >= 0x80) {
    put_byte(b, (uint8_t)(v | 0x80));
    v >>= 7;
  }
  put_byte(b, (uint8_t)v);
}

// append a field tag
static void put_tag(struct hd_buf* b, unsigned field, unsigned wt) {
  put_varint(b, ((uint64_t)field << 3) | wt);
}

// append a varint field
static void put_u(struct hd_buf* b, unsigned field, uint64_t v) {
  put_tag(b, field, WT_VARINT);
  put_varint(b, v);
}

// write a signed varint field
static void put_i(struct hd_buf* b, unsigned field, int64_t v) { put_u(b, field, (uint64_t)v); }

// append a length-delimited field
static void put_bytes(struct hd_buf* b, unsigned field, const void* p, size_t n) {
  put_tag(b, field, WT_LEN);
  put_varint(b, n);
  if (b->len + n > b->cap) {
    b->overflow = true;
    return;
  }
  memcpy(b->data + b->len, p, n);
  b->len += n;
}

// append a string field
static void put_str(struct hd_buf* b, unsigned field, const char* s) {
  put_bytes(b, field, s, strlen(s));
}

// append the inner message to b
static void put_msg(struct hd_buf* b, unsigned field, const struct hd_buf* inner) {
  if (inner->overflow) b->overflow = true;
  put_bytes(b, field, inner->data, inner->len);
}

#define SUB(name, size)                      \
  uint8_t name##_mem[size];                  \
  struct hd_buf name = {name##_mem, size, 0, false}

// append the timestamp and clock id fields
static void header(struct hd_buf* b, uint64_t ts) {
  put_u(b, F_TIMESTAMP, ts);
  put_u(b, F_CLOCK_ID, CLOCK_BOOTTIME);
}

static uint64_t mix(uint64_t x) {
  x ^= x >> 30;
  x *= 0xbf58476d1ce4e5b9ULL;
  x ^= x >> 27;
  x *= 0x94d049bb133111ebULL;
  x ^= x >> 31;
  return x;
}

// return a nonzero id mixed from a kind and two values
static uint64_t uuid_of(uint64_t kind, uint64_t a, uint64_t b) {
  uint64_t u = mix(mix(kind * 0x9e3779b97f4a7c15ULL + a) ^ b);
  return u ? u : 1;
}

// return the track id of a thread
uint64_t hd_uuid_thread(int32_t pid, int32_t tid) { return uuid_of(1, (uint32_t)pid, (uint32_t)tid); }
// return the track id of a process
uint64_t hd_uuid_process(int32_t pid) { return uuid_of(2, (uint32_t)pid, 0); }
// return the track id of a counter
uint64_t hd_uuid_counter(int32_t pid, int which) { return uuid_of(3, (uint32_t)pid, (uint64_t)which); }

// build a thread track descriptor packet
void hd_pb_thread_track(struct hd_buf* b, uint64_t ts, uint64_t uuid, int32_t pid,
                        int32_t tid, const char* name) {
  SUB(thr, 192);
  put_i(&thr, F_THD_PID, pid);
  put_i(&thr, F_THD_TID, tid);
  if (name && *name) put_str(&thr, F_THD_NAME, name);
  SUB(td, 256);
  put_u(&td, F_TD_UUID, uuid);
  put_msg(&td, F_TD_THREAD, &thr);
  header(b, ts);
  put_msg(b, F_TRACK_DESCRIPTOR, &td);
}

// build a process track descriptor packet
void hd_pb_process_track(struct hd_buf* b, uint64_t ts, uint64_t uuid, int32_t pid,
                         const char* name) {
  SUB(proc, 192);
  put_i(&proc, F_PD_PID, pid);
  if (name && *name) put_str(&proc, F_PD_NAME, name);
  SUB(td, 256);
  put_u(&td, F_TD_UUID, uuid);
  put_msg(&td, F_TD_PROCESS, &proc);
  header(b, ts);
  put_msg(b, F_TRACK_DESCRIPTOR, &td);
}

// write a counter track descriptor packet
void hd_pb_counter_track(struct hd_buf* b, uint64_t ts, uint64_t uuid, uint64_t parent,
                         const char* name) {
  SUB(td, 192);
  put_u(&td, F_TD_UUID, uuid);
  put_u(&td, F_TD_PARENT, parent);
  put_str(&td, F_TD_NAME, name);
  put_bytes(&td, F_TD_COUNTER, "", 0);
  header(b, ts);
  put_msg(b, F_TRACK_DESCRIPTOR, &td);
}

// append an integer debug annotation
static void put_int_annotation(struct hd_buf* te, const char* name, int64_t v) {
  SUB(da, 64);
  put_str(&da, F_DA_NAME, name);
  put_i(&da, F_DA_INT, v);
  put_msg(te, F_TE_DEBUG, &da);
}

// build a slice begin packet with held time and work period
void hd_pb_slice_begin(struct hd_buf* b, uint64_t ts, uint64_t uuid, const char* name,
                       int64_t held_us, int64_t work_period) {
  SUB(te, 192);
  put_u(&te, F_TE_TYPE, TYPE_SLICE_BEGIN);
  put_u(&te, F_TE_UUID, uuid);
  put_str(&te, F_TE_NAME, name);
  put_int_annotation(&te, "held_us", held_us);
  put_int_annotation(&te, "work_period", work_period);
  header(b, ts);
  put_msg(b, F_TRACK_EVENT, &te);
}

// build a slice end packet
void hd_pb_slice_end(struct hd_buf* b, uint64_t ts, uint64_t uuid) {
  SUB(te, 32);
  put_u(&te, F_TE_TYPE, TYPE_SLICE_END);
  put_u(&te, F_TE_UUID, uuid);
  header(b, ts);
  put_msg(b, F_TRACK_EVENT, &te);
}

// build a counter value packet
void hd_pb_counter_value(struct hd_buf* b, uint64_t ts, uint64_t uuid, int64_t value) {
  SUB(te, 48);
  put_u(&te, F_TE_TYPE, TYPE_COUNTER);
  put_u(&te, F_TE_UUID, uuid);
  put_i(&te, F_TE_COUNTER, value);
  header(b, ts);
  put_msg(b, F_TRACK_EVENT, &te);
}
