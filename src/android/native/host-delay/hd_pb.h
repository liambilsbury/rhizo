#ifndef RHIZO_HD_PB_H
#define RHIZO_HD_PB_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define HD_PB_PACKET_MAX 640

struct hd_buf {
  uint8_t* data;
  size_t cap, len;
  bool overflow;
};

#define HD_SLICE_NAME "held off by the host"
#define HD_COUNTER_WP "rhizo work periods"
#define HD_COUNTER_DELAYED "rhizo host-delayed work periods"
#define HD_COUNTER_DELAYS "rhizo host delays"
#define HD_COUNTER_HELD "rhizo held us"
uint64_t hd_uuid_thread(int32_t pid, int32_t tid);
uint64_t hd_uuid_process(int32_t pid);
uint64_t hd_uuid_counter(int32_t pid, int which);

void hd_pb_thread_track(struct hd_buf* b, uint64_t ts, uint64_t uuid, int32_t pid,
                        int32_t tid, const char* name);
void hd_pb_process_track(struct hd_buf* b, uint64_t ts, uint64_t uuid, int32_t pid,
                         const char* name);
void hd_pb_counter_track(struct hd_buf* b, uint64_t ts, uint64_t uuid, uint64_t parent,
                         const char* name);
void hd_pb_slice_begin(struct hd_buf* b, uint64_t ts, uint64_t uuid, const char* name,
                       int64_t held_us, int64_t work_period);
void hd_pb_slice_end(struct hd_buf* b, uint64_t ts, uint64_t uuid);
void hd_pb_counter_value(struct hd_buf* b, uint64_t ts, uint64_t uuid, int64_t value);

#endif
