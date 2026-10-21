#define _GNU_SOURCE
#include <android/binder_ibinder.h>
#include <android/binder_process.h>
#include <android/binder_status.h>
#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "hd_core.h"
#include "perfetto/public/data_source.h"
#include "perfetto/public/pb_msg.h"
#include "perfetto/public/producer.h"

#define LOG_TAG "rhizo-host-delay"
#define SOCKET_PATH "/dev/socket/rhizo_delay/delayd"
#define SERVICE_NAME "rhizo.host_delay"
#define DATA_SOURCE_NAME "rhizo.host_delay"
#define RECONNECT_SECONDS 1
#define PACKET_MAX 4096

binder_exception_t AServiceManager_addService(AIBinder* binder, const char* instance);

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct hd_table g_table;
static atomic_bool g_connected;
static struct PerfettoDs g_ds = PERFETTO_DS_INIT();

// write a line to the kernel log
static void kmsg(const char* line) {
  int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (fd < 0) return;
  ssize_t r = write(fd, line, strlen(line));
  (void)r;
  close(fd);
}

// return the boottime clock in nanoseconds
static uint64_t boottime_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_BOOTTIME, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

// ignore the data source setup
static void* ds_on_setup(struct PerfettoDsImpl* impl, PerfettoDsInstanceIndex inst, void* cfg,
                         size_t cfg_size, void* user_arg, struct PerfettoDsOnSetupArgs* args) {
  (void)impl; (void)inst; (void)cfg; (void)cfg_size; (void)user_arg; (void)args;
  return NULL;
}

// log that a trace instance started
static void ds_on_start(struct PerfettoDsImpl* impl, PerfettoDsInstanceIndex inst, void* user_arg,
                        void* inst_ctx, struct PerfettoDsOnStartArgs* args) {
  (void)impl; (void)user_arg; (void)inst_ctx; (void)args;
  __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "trace instance %u started", inst);
}

// log that a trace instance stopped
static void ds_on_stop(struct PerfettoDsImpl* impl, PerfettoDsInstanceIndex inst, void* user_arg,
                       void* inst_ctx, struct PerfettoDsOnStopArgs* args) {
  (void)impl; (void)user_arg; (void)inst_ctx; (void)args;
  __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "trace instance %u stopped", inst);
}

// allocate an empty hd_incr
static void* ds_create_incr(struct PerfettoDsImpl* impl, PerfettoDsInstanceIndex inst,
                            struct PerfettoDsTracerImpl* tracer, void* user_arg) {
  (void)impl; (void)inst; (void)tracer; (void)user_arg;
  return calloc(1, sizeof(struct hd_incr));
}

// free an incremental-state object
static void ds_delete_incr(void* obj) {
  if (!obj) return;
  hd_incr_free(obj);
  free(obj);
}

// initialize the producer and register the data source
static bool trace_init(void) {
  struct PerfettoProducerInitArgs a = PERFETTO_PRODUCER_INIT_ARGS_INIT();
  a.backends = PERFETTO_BACKEND_SYSTEM;
  PerfettoProducerInit(a);
  struct PerfettoDsParams params = PerfettoDsParamsDefault();
  params.on_setup_cb = ds_on_setup;
  params.on_start_cb = ds_on_start;
  params.on_stop_cb = ds_on_stop;
  params.on_create_incr_cb = ds_create_incr;
  params.on_delete_incr_cb = ds_delete_incr;
  return PerfettoDsRegister(&g_ds, DATA_SOURCE_NAME, params);
}

// write a packet body to the trace
static void sink(void* arg, const uint8_t* body, size_t len) {
  struct PerfettoDsTracerIterator* it = arg;
  struct PerfettoDsRootTracePacket p;
  PerfettoDsTracerPacketBegin(it, &p);
  PerfettoPbMsgAppendBytes(&p.msg.msg, body, len);
  PerfettoDsTracerPacketEnd(it, &p);
}

// emit baselines to each trace instance
static void baseline_instances(int32_t pid) {
  uint64_t now = boottime_ns();
  PERFETTO_DS_TRACE(g_ds, it) {
    struct hd_incr* seen = PerfettoDsGetIncrementalState(&g_ds, &it);
    if (seen) {
      hd_emit_baseline(&g_table, seen, now, sink, &it);
      hd_emit_baseline_pid(&g_table, seen, pid, now, sink, &it);
    }
  }
}

// emit the packets for l to each instance
static void emit_to_instances(const struct hd_line* l) {
  uint64_t now = boottime_ns();
  PERFETTO_DS_TRACE(g_ds, it) {
    struct hd_incr* seen = PerfettoDsGetIncrementalState(&g_ds, &it);
    if (seen) hd_emit_line(&g_table, seen, l, now, sink, &it);
  }
}

// apply a host line and emit it to the trace instances
static void on_line(const struct hd_line* l, void* arg) {
  (void)arg;
  pthread_mutex_lock(&g_lock);
  baseline_instances(l->pid);
  if (hd_table_apply(&g_table, l) && (l->kind == HD_D || l->kind == HD_C)) emit_to_instances(l);
  pthread_mutex_unlock(&g_lock);
}

// return the service arguments as its data
static void* svc_create(void* args) { return args; }
// ignore the service data on destroy
static void svc_destroy(void* data) { (void)data; }

// reject all of the transaction codes
static binder_status_t svc_transact(AIBinder* binder, transaction_code_t code, const AParcel* in,
                                    AParcel* out) {
  (void)binder; (void)code; (void)in; (void)out;
  return STATUS_UNKNOWN_TRANSACTION;
}

// write all bytes to a descriptor
static void write_all(int fd, const char* p, size_t n) {
  while (n) {
    ssize_t w = write(fd, p, n);
    if (w < 0 && errno == EINTR) continue;
    if (w <= 0) return;
    p += w;
    n -= (size_t)w;
  }
}

// write the table dump to fd
static binder_status_t svc_dump(AIBinder* binder, int fd, const char** args, uint32_t nargs) {
  (void)binder; (void)args; (void)nargs;
  size_t len = 0;
  pthread_mutex_lock(&g_lock);
  char* text = hd_table_dump(&g_table, atomic_load(&g_connected), &len);
  pthread_mutex_unlock(&g_lock);
  if (!text) return STATUS_NO_MEMORY;
  write_all(fd, text, len);
  free(text);
  return STATUS_OK;
}

// register the binder service with a dump handler
static bool serve_binder(void) {
  AIBinder_Class* cls = AIBinder_Class_define(SERVICE_NAME, svc_create, svc_destroy, svc_transact);
  if (!cls) return false;
  AIBinder_Class_setOnDump(cls, svc_dump);
  AIBinder* binder = AIBinder_new(cls, NULL);
  if (!binder) return false;
  ABinderProcess_setThreadPoolMaxThreadCount(2);
  ABinderProcess_startThreadPool();
  return AServiceManager_addService(binder, SERVICE_NAME) == STATUS_OK;
}

// connect to the host socket
static int connect_host(void) {
  int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  strncpy(addr.sun_path, SOCKET_PATH, sizeof addr.sun_path - 1);
  if (connect(fd, (struct sockaddr*)&addr, sizeof addr) < 0) {
    close(fd);
    return -1;
  }
  return fd;
}

// read protocol packets from the host socket
static void read_host(int fd) {
  static char buf[PACKET_MAX];
  size_t rejected_total = 0;
  for (;;) {
    ssize_t n = recv(fd, buf, sizeof buf, MSG_TRUNC);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return;
    size_t bad = (size_t)n > sizeof buf ? 1 : hd_for_each_line(buf, (size_t)n, on_line, NULL);
    if (!bad) continue;
    unsigned long long before = rejected_total;
    rejected_total += bad;
    if (before == 0 || __builtin_clzll(before) != __builtin_clzll(rejected_total))
      __android_log_print(ANDROID_LOG_WARN, LOG_TAG, "%zu protocol line(s) rejected so far",
                          rejected_total);
  }
}

// serve binder and keep reconnecting to the host
int main(void) {
  signal(SIGPIPE, SIG_IGN);
  hd_table_init(&g_table);
  if (!trace_init()) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "data source not registered");
  if (!serve_binder()) {
    __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "could not register " SERVICE_NAME);
    return 1;
  }
  for (;;) {
    int fd = connect_host();
    if (fd >= 0) {
      atomic_store(&g_connected, true);
      kmsg("RHIZO_MARKER host_delay=connected\n");
      read_host(fd);
      close(fd);
      atomic_store(&g_connected, false);
      kmsg("RHIZO_MARKER host_delay=disconnected\n");
    }
    sleep(RECONNECT_SECONDS);
  }
}
