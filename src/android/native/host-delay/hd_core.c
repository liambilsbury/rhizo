#include "hd_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hd_pb.h"

struct cursor {
  const char* p;
  const char* end;
};

// parse an unsigned decimal field
static bool take_num(struct cursor* c, uint64_t max, uint64_t* out) {
  uint64_t v = 0;
  size_t digits = 0;
  while (c->p < c->end && *c->p >= '0' && *c->p <= '9') {
    unsigned d = (unsigned)(*c->p - '0');
    if (v > (UINT64_MAX - d) / 10) return false;
    v = v * 10 + d;
    digits++;
    c->p++;
  }
  if (digits == 0 || v > max) return false;
  *out = v;
  return true;
}

// consume a space from the cursor
static bool take_space(struct cursor* c) {
  if (c->p >= c->end || *c->p != ' ') return false;
  c->p++;
  return true;
}

// parse a positive pid from the cursor
static bool take_pid(struct cursor* c, int32_t* out) {
  uint64_t v;
  if (!take_num(c, INT32_MAX, &v) || v == 0) return false;
  *out = (int32_t)v;
  return true;
}

// parse a process or thread name
static bool take_name(struct cursor* c, char* out) {
  size_t n = (size_t)(c->end - c->p);
  if (n == 0 || n > HD_NAME_MAX) return false;
  for (size_t i = 0; i < n; i++) {
    unsigned char ch = (unsigned char)c->p[i];
    if (ch <= 0x20 || ch == 0x7f) return false;
  }
  memcpy(out, c->p, n);
  out[n] = '\0';
  c->p += n;
  return true;
}

// return whether the cursor is at the end
static bool at_end(const struct cursor* c) { return c->p == c->end; }

// parse a protocol line
bool hd_parse_line(const char* s, size_t n, struct hd_line* out) {
  memset(out, 0, sizeof *out);
  if (n < 2 || s[1] != ' ') return false;
  struct cursor c = {s + 2, s + n};
  bool ok = false;
  switch (s[0]) {
    case 'p':
      out->kind = HD_P;
      ok = take_pid(&c, &out->pid) && take_space(&c) && take_name(&c, out->name);
      break;
    case 't':
      out->kind = HD_T;
      ok = take_pid(&c, &out->pid) && take_space(&c) && take_pid(&c, &out->tid) &&
           take_space(&c) && take_name(&c, out->name);
      break;
    case 'd':
      out->kind = HD_D;
      ok = take_pid(&c, &out->pid) && take_space(&c) && take_pid(&c, &out->tid) &&
           take_space(&c) && take_num(&c, UINT64_MAX, &out->start_ns) && take_space(&c) &&
           take_num(&c, UINT64_MAX, &out->end_ns) && take_space(&c) &&
           take_num(&c, UINT64_MAX, &out->held_ns) && take_space(&c) &&
           take_num(&c, INT64_MAX, &out->wp) && at_end(&c);
      if (ok && (out->end_ns < out->start_ns || out->held_ns > out->end_ns - out->start_ns))
        ok = false;
      break;
    case 'c':
      out->kind = HD_C;
      ok = take_pid(&c, &out->pid) && take_space(&c) &&
           take_num(&c, INT64_MAX, &out->work_periods) && take_space(&c) &&
           take_num(&c, INT64_MAX, &out->host_delayed) && at_end(&c);
      break;
    case 'x':
      out->kind = HD_X;
      ok = take_pid(&c, &out->pid) && at_end(&c);
      break;
    default:
      break;
  }
  if (!ok) memset(out, 0, sizeof *out);
  return ok;
}

// call cb for each valid line
size_t hd_for_each_line(const char* buf, size_t len, void (*cb)(const struct hd_line*, void*),
                        void* arg) {
  size_t bad = 0, i = 0;
  while (i < len) {
    const char* nl = memchr(buf + i, '\n', len - i);
    if (!nl) {
      bad++;
      break;
    }
    struct hd_line l;
    if (hd_parse_line(buf + i, (size_t)(nl - (buf + i)), &l))
      cb(&l, arg);
    else
      bad++;
    i = (size_t)(nl - buf) + 1;
  }
  return bad;
}

// zero a table
void hd_table_init(struct hd_table* t) { memset(t, 0, sizeof *t); }

// free the table arrays and zero it
void hd_table_free(struct hd_table* t) {
  free(t->apps);
  free(t->threads);
  memset(t, 0, sizeof *t);
}

// return the app with the given pid, or null
static struct hd_app* find_app(const struct hd_table* t, int32_t pid) {
  for (size_t i = 0; i < t->n; i++)
    if (t->apps[i].pid == pid) return &t->apps[i];
  return NULL;
}

// return the app with the given pid, or null
const struct hd_app* hd_table_app(const struct hd_table* t, int32_t pid) {
  return find_app(t, pid);
}

// copy a name into a fixed-size buffer
static void set_name(char* dst, const char* src) {
  snprintf(dst, HD_NAME_MAX + 1, "%s", src);
}

// remove all of the threads of a pid from the table
static void drop_threads_of(struct hd_table* t, int32_t pid) {
  size_t w = 0;
  for (size_t i = 0; i < t->tn; i++)
    if (t->threads[i].pid != pid) t->threads[w++] = t->threads[i];
  t->tn = w;
}

// return the live row for pid
static struct hd_app* live_app(struct hd_table* t, int32_t pid, bool restart) {
  struct hd_app* a = find_app(t, pid);
  if (a && a->exited && !restart) return NULL;
  if (a && a->exited) {
    t->n_exited--;
    memset(a, 0, sizeof *a);
    a->pid = pid;
    return a;
  }
  if (a) return a;
  if (t->n == t->cap) {
    size_t cap = t->cap ? t->cap * 2 : 64;
    struct hd_app* na = realloc(t->apps, cap * sizeof *na);
    if (!na) return NULL;
    t->apps = na;
    t->cap = cap;
  }
  a = &t->apps[t->n++];
  memset(a, 0, sizeof *a);
  a->pid = pid;
  set_name(a->name, "?");
  return a;
}

// remove the app that exited earliest
static void forget_oldest_exited(struct hd_table* t) {
  size_t oldest = t->n;
  for (size_t i = 0; i < t->n; i++)
    if (t->apps[i].exited && (oldest == t->n || t->apps[i].exit_seq < t->apps[oldest].exit_seq))
      oldest = i;
  if (oldest == t->n) return;
  t->apps[oldest] = t->apps[--t->n];
  t->n_exited--;
}

// set the name of a thread
static bool upsert_thread(struct hd_table* t, int32_t pid, int32_t tid, const char* name) {
  for (size_t i = 0; i < t->tn; i++)
    if (t->threads[i].pid == pid && t->threads[i].tid == tid) {
      set_name(t->threads[i].name, name);
      return true;
    }
  if (t->tn == t->tcap) {
    size_t cap = t->tcap ? t->tcap * 2 : 256;
    struct hd_thread* nt = realloc(t->threads, cap * sizeof *nt);
    if (!nt) return false;
    t->threads = nt;
    t->tcap = cap;
  }
  t->threads[t->tn].pid = pid;
  t->threads[t->tn].tid = tid;
  set_name(t->threads[t->tn].name, name);
  t->tn++;
  return true;
}

// apply a parsed line to the table
bool hd_table_apply(struct hd_table* t, const struct hd_line* l) {
  struct hd_app* a;
  switch (l->kind) {
    case HD_P:
      a = live_app(t, l->pid, true);
      if (!a) return false;
      set_name(a->name, l->name);
      return true;
    case HD_T:
      a = find_app(t, l->pid);
      if (a && a->exited) return false;
      return upsert_thread(t, l->pid, l->tid, l->name);
    case HD_D:
      a = live_app(t, l->pid, false);
      if (!a) return false;
      a->delays++;
      a->held_us += l->held_ns / 1000;
      return true;
    case HD_C:
      a = live_app(t, l->pid, false);
      if (!a) return false;
      a->work_periods = l->work_periods;
      a->host_delayed = l->host_delayed;
      return true;
    case HD_X:
      a = find_app(t, l->pid);
      if (!a || a->exited) return false;
      a->exited = true;
      a->exit_seq = ++t->exit_seq;
      t->n_exited++;
      drop_threads_of(t, l->pid);
      while (t->n_exited > HD_EXITED_KEEP) forget_oldest_exited(t);
      return true;
    default:
      return false;
  }
}

// return the name of a thread, or null
const char* hd_table_thread_name(const struct hd_table* t, int32_t pid, int32_t tid) {
  for (size_t i = 0; i < t->tn; i++)
    if (t->threads[i].pid == pid && t->threads[i].tid == tid) return t->threads[i].name;
  return NULL;
}

// compare two apps by pid
static int by_pid(const void* x, const void* y) {
  const struct hd_app* a = x;
  const struct hd_app* b = y;
  return (a->pid > b->pid) - (a->pid < b->pid);
}

// format the table for dumpsys
char* hd_table_dump(const struct hd_table* t, bool connected, size_t* len) {
  struct hd_app* rows = malloc((t->n ? t->n : 1) * sizeof *rows);
  if (!rows) return NULL;
  if (t->n) memcpy(rows, t->apps, t->n * sizeof *rows);
  qsort(rows, t->n, sizeof *rows, by_pid);
  size_t cap = 160 + t->n * (HD_NAME_MAX + 160);
  char* out = malloc(cap);
  if (!out) {
    free(rows);
    return NULL;
  }
  size_t n = (size_t)snprintf(out, cap, "rhizo host delay: connected=%s\n%s",
                              connected ? "yes" : "no",
                              "pid\tprocess\twork_periods\thost_delayed\tdelays\theld_us\tstate\n");
  for (size_t i = 0; i < t->n; i++) {
    const struct hd_app* a = &rows[i];
    n += (size_t)snprintf(out + n, cap - n, "%d\t%s\t%llu\t%llu\t%llu\t%llu\t%s\n", a->pid,
                          a->name, (unsigned long long)a->work_periods,
                          (unsigned long long)a->host_delayed, (unsigned long long)a->delays,
                          (unsigned long long)a->held_us, a->exited ? "exited" : "live");
  }
  free(rows);
  *len = n;
  return out;
}

// free the seen-key set and zero it
void hd_incr_free(struct hd_incr* s) {
  free(s->keys);
  memset(s, 0, sizeof *s);
}

// return the FNV-1a hash of a string
static uint64_t fnv(const char* s) {
  uint64_t h = 1469598103934665603ULL;
  for (; s && *s; s++) h = (h ^ (unsigned char)*s) * 1099511628211ULL;
  return h;
}

static bool incr_insert(struct hd_incr* s, uint64_t key);

// double the seen-key set and re-insert its keys
static bool incr_grow(struct hd_incr* s) {
  size_t cap = s->cap ? s->cap * 2 : 256;
  struct hd_incr bigger = {calloc(cap, sizeof(uint64_t)), 0, cap, s->baselined};
  if (!bigger.keys) return false;
  for (size_t i = 0; i < s->cap; i++)
    if (s->keys[i]) incr_insert(&bigger, s->keys[i]);
  free(s->keys);
  *s = bigger;
  return true;
}

// insert key into the seen set
static bool incr_insert(struct hd_incr* s, uint64_t key) {
  if (!key) key = 1;
  if ((s->n + 1) * 2 > s->cap && !incr_grow(s)) return true;
  size_t mask = s->cap - 1, i = (size_t)(key * 0x9e3779b97f4a7c15ULL >> 20) & mask;
  while (s->keys[i]) {
    if (s->keys[i] == key) return false;
    i = (i + 1) & mask;
  }
  s->keys[i] = key;
  s->n++;
  return true;
}

// insert a track and name key
static bool first_time(struct hd_incr* s, uint64_t uuid, const char* name) {
  return incr_insert(s, uuid ^ (fnv(name) * 0xff51afd7ed558ccdULL) ^ 0x5bd1e995);
}

// pass a packet to the sink unless it overflowed
static void emit(hd_sink_fn sink, void* arg, struct hd_buf* b) {
  if (!b->overflow) sink(arg, b->data, b->len);
}

#define PACKET(b) \
  uint8_t b##_mem[HD_PB_PACKET_MAX]; \
  struct hd_buf b = {b##_mem, sizeof b##_mem, 0, false}

static const char* const k_counter_names[4] = {HD_COUNTER_WP, HD_COUNTER_DELAYED,
                                               HD_COUNTER_DELAYS, HD_COUNTER_HELD};

// emit a process track the first time a process is seen
static void ensure_process(struct hd_incr* seen, int32_t pid, const char* name, uint64_t now_ns,
                           hd_sink_fn sink, void* arg) {
  uint64_t proc = hd_uuid_process(pid);
  if (!first_time(seen, proc, name)) return;
  PACKET(b);
  hd_pb_process_track(&b, now_ns, proc, pid, name);
  emit(sink, arg, &b);
}

// write a counter value packet
static void put_counter(struct hd_incr* seen, int32_t pid, int which, uint64_t value,
                        uint64_t now_ns, hd_sink_fn sink, void* arg) {
  uint64_t uuid = hd_uuid_counter(pid, which);
  if (first_time(seen, uuid, k_counter_names[which])) {
    PACKET(b);
    hd_pb_counter_track(&b, now_ns, uuid, hd_uuid_process(pid), k_counter_names[which]);
    emit(sink, arg, &b);
  }
  PACKET(bv);
  hd_pb_counter_value(&bv, now_ns, uuid, (int64_t)value);
  emit(sink, arg, &bv);
}

static bool mark_baselined(struct hd_incr* seen, int32_t pid) {
  return first_time(seen, hd_uuid_process(pid), "\001baselined");
}

// emit the process track and the four counters of an app
static void baseline_app(struct hd_incr* seen, int32_t pid, const struct hd_app* a, uint64_t now_ns,
                         hd_sink_fn sink, void* arg) {
  const uint64_t vals[4] = {a ? a->work_periods : 0, a ? a->host_delayed : 0, a ? a->delays : 0,
                            a ? a->held_us : 0};
  ensure_process(seen, pid, a ? a->name : "", now_ns, sink, arg);
  for (int w = 0; w < 4; w++) put_counter(seen, pid, w, vals[w], now_ns, sink, arg);
}

// emit the baseline for all of the apps once
void hd_emit_baseline(const struct hd_table* t, struct hd_incr* seen, uint64_t now_ns,
                      hd_sink_fn sink, void* arg) {
  if (seen->baselined) return;
  seen->baselined = true;
  for (size_t i = 0; i < t->n; i++)
    if (mark_baselined(seen, t->apps[i].pid))
      baseline_app(seen, t->apps[i].pid, &t->apps[i], now_ns, sink, arg);
}

// emit the baseline for a pid once
void hd_emit_baseline_pid(const struct hd_table* t, struct hd_incr* seen, int32_t pid,
                          uint64_t now_ns, hd_sink_fn sink, void* arg) {
  if (mark_baselined(seen, pid)) baseline_app(seen, pid, hd_table_app(t, pid), now_ns, sink, arg);
}

// emit the packets for a line
void hd_emit_line(const struct hd_table* t, struct hd_incr* seen, const struct hd_line* l,
                  uint64_t now_ns, hd_sink_fn sink, void* arg) {
  if (l->kind == HD_D) {
    uint64_t uuid = hd_uuid_thread(l->pid, l->tid);
    const char* name = hd_table_thread_name(t, l->pid, l->tid);
    if (first_time(seen, uuid, name ? name : "")) {
      PACKET(b);
      hd_pb_thread_track(&b, l->start_ns, uuid, l->pid, l->tid, name);
      emit(sink, arg, &b);
    }
    PACKET(bb);
    hd_pb_slice_begin(&bb, l->start_ns, uuid, HD_SLICE_NAME, (int64_t)(l->held_ns / 1000),
                      (int64_t)l->wp);
    emit(sink, arg, &bb);
    PACKET(be);
    hd_pb_slice_end(&be, l->end_ns, uuid);
    emit(sink, arg, &be);
    const struct hd_app* a = hd_table_app(t, l->pid);
    if (a) {
      ensure_process(seen, l->pid, a->name, now_ns, sink, arg);
      put_counter(seen, l->pid, 2, a->delays, now_ns, sink, arg);
      put_counter(seen, l->pid, 3, a->held_us, now_ns, sink, arg);
    }
  } else if (l->kind == HD_C) {
    const struct hd_app* a = hd_table_app(t, l->pid);
    ensure_process(seen, l->pid, a ? a->name : "?", now_ns, sink, arg);
    put_counter(seen, l->pid, 0, l->work_periods, now_ns, sink, arg);
    put_counter(seen, l->pid, 1, l->host_delayed, now_ns, sink, arg);
  }
}
