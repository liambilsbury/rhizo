#ifndef RHIZO_HD_CORE_H
#define RHIZO_HD_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define HD_NAME_MAX 127
#define HD_EXITED_KEEP 512

enum hd_kind { HD_BAD = 0, HD_P, HD_T, HD_D, HD_C, HD_X };

// parsed protocol line
struct hd_line {
  enum hd_kind kind;
  int32_t pid, tid;
  uint64_t start_ns, end_ns, held_ns;
  uint64_t wp;
  uint64_t work_periods, host_delayed;
  char name[HD_NAME_MAX + 1];
};

bool hd_parse_line(const char* s, size_t n, struct hd_line* out);

size_t hd_for_each_line(const char* buf, size_t len,
                        void (*cb)(const struct hd_line*, void*), void* arg);

// delay counters for a process
struct hd_app {
  int32_t pid;
  char name[HD_NAME_MAX + 1];
  uint64_t work_periods, host_delayed, delays, held_us;
  bool exited;
  uint64_t exit_seq;
};

struct hd_thread {
  int32_t pid, tid;
  char name[HD_NAME_MAX + 1];
};

struct hd_table {
  struct hd_app* apps;
  size_t n, cap, n_exited;
  uint64_t exit_seq;
  struct hd_thread* threads;
  size_t tn, tcap;
};

void hd_table_init(struct hd_table* t);
void hd_table_free(struct hd_table* t);

bool hd_table_apply(struct hd_table* t, const struct hd_line* l);

const struct hd_app* hd_table_app(const struct hd_table* t, int32_t pid);
const char* hd_table_thread_name(const struct hd_table* t, int32_t pid, int32_t tid);

char* hd_table_dump(const struct hd_table* t, bool connected, size_t* len);

// track descriptors sent to a trace
struct hd_incr {
  uint64_t* keys;
  size_t n, cap;
  bool baselined;
};
void hd_incr_free(struct hd_incr* s);

typedef void (*hd_sink_fn)(void* arg, const uint8_t* body, size_t len);

void hd_emit_baseline(const struct hd_table* t, struct hd_incr* seen, uint64_t now_ns,
                      hd_sink_fn sink, void* arg);

void hd_emit_baseline_pid(const struct hd_table* t, struct hd_incr* seen, int32_t pid,
                          uint64_t now_ns, hd_sink_fn sink, void* arg);

void hd_emit_line(const struct hd_table* t, struct hd_incr* seen, const struct hd_line* l,
                  uint64_t now_ns, hd_sink_fn sink, void* arg);

#endif
