#define _GNU_SOURCE
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "hd_core.h"
#include "hd_pb.h"

static int g_fail;

// record and print a check result
static void check(bool ok, const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  if (!ok) {
    fprintf(stderr, "FAIL: ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    g_fail++;
  } else {
    printf("ok: ");
    vprintf(fmt, ap);
    putchar('\n');
  }
  va_end(ap);
}

// apply a parsed line to the table
static void apply_cb(const struct hd_line* l, void* arg) { hd_table_apply(arg, l); }

// apply all of the lines of a text to the table
static size_t feed(struct hd_table* t, const char* text) {
  return hd_for_each_line(text, strlen(text), apply_cb, t);
}

// return whether a line parses
static bool parses(const char* line) {
  struct hd_line l;
  return hd_parse_line(line, strlen(line), &l);
}

// test the protocol line parser
static void test_parser(void) {
  struct hd_line l;
  const char* d = "d 1000 1010 5010000000 5012500000 2500000 8";
  check(hd_parse_line(d, strlen(d), &l) && l.kind == HD_D && l.pid == 1000 && l.tid == 1010 &&
            l.start_ns == 5010000000ull && l.end_ns == 5012500000ull && l.held_ns == 2500000 &&
            l.wp == 8,
        "d line parses to its six fields");
  check(parses("p 7 com.example.app") && parses("t 7 8 RenderThread") && parses("c 7 12 3") &&
            parses("x 7"),
        "p, t, c and x lines parse");
  check(parses("d 1 1 10 10 0 0"), "an empty episode (start == end, held 0) parses");
  char name127[200], name128[200];
  memset(name127, 'a', 127);
  memset(name128, 'a', 128);
  snprintf(name127 + 127, 20, "%c", 0);
  snprintf(name128 + 128, 20, "%c", 0);
  char line[400];
  snprintf(line, sizeof line, "p 5 %s", name127);
  check(parses(line), "a 127-byte process name parses");
  snprintf(line, sizeof line, "p 5 %s", name128);
  check(!parses(line), "a 128-byte process name is rejected");

  static const char* const bad[] = {
      "", " ", "p", "p ", "p 5", "p 5 ", "p 0 name", "p -1 name", "p 5 a b", "p 5  name",
      "p  5 name", "p 5 na\tme", "p 5 na\x01me", "p 99999999999 name", "p 2147483648 name",
      "p +5 name", "p 5x name", "t 5 name", "t 5 6", "t 5 0 name", "t 5 6 a b",
      "d 1 2 3 4 5", "d 1 2 3 4 5 6 7", "d 1 2 3 4 5 x", "d 1 2 20 10 0 1",
      "d 1 2 10 20 11 1", "d 1 2 10 20 5 -1", "d 1 2 10 20 5 9223372036854775808",
      "d 1 2 18446744073709551616 18446744073709551617 0 0", "d 1 2 10 20 5 6 ",
      "c 1", "c 1 2", "c 1 2 3 4", "c 1 -2 3", "c 1 9223372036854775808 3", "x", "x 0",
      "x 5 6", "x 5 ", "z 5", "P 5 name", "pp 5 name", "d1 2 3", "p5 name",
  };
  size_t rejected = 0;
  for (size_t i = 0; i < sizeof bad / sizeof *bad; i++)
    if (!parses(bad[i])) rejected++;
  check(rejected == sizeof bad / sizeof *bad, "all %zu malformed lines are rejected (%zu were)",
        sizeof bad / sizeof *bad, rejected);

  struct hd_table t;
  hd_table_init(&t);
  size_t n = feed(&t, "p 5 good\nnot a line\nc 5 1 1\nd 5 6 10 5 0 1\ntrailing");
  const struct hd_app* a = hd_table_app(&t, 5);
  check(n == 3 && a && a->work_periods == 1 && a->delays == 0,
        "a packet applies its good lines, counts its bad ones (%zu) and the unterminated tail", n);
  hd_table_free(&t);
}

// test the per-app table
static void test_table(void) {
  struct hd_table t;
  hd_table_init(&t);
  size_t bad = 0;
  bad += feed(&t, "p 1000 com.example.app\n"
                  "t 1000 1000 ample.app\n"
                  "t 1000 1010 RenderThread\n"
                  "d 1000 1000 5000000000 5003000000 2500000 7\n"
                  "d 1000 1010 5010000000 5012500000 2500000 8\n"
                  "d 1000 1000 5100000000 5100600000 600000 9\n"
                  "c 1000 9 2\n");
  const struct hd_app* a = hd_table_app(&t, 1000);
  check(bad == 0 && a && a->delays == 3 && a->held_us == 5600 && a->work_periods == 9 &&
            a->host_delayed == 2 && !a->exited,
        "records and a c line fold into the app's row");
  feed(&t, "p 1000 com.example.renamed\nt 1000 1010 hwuiTask1\n");
  a = hd_table_app(&t, 1000);
  check(a && !strcmp(a->name, "com.example.renamed") && a->delays == 3 && a->work_periods == 9,
        "a p line renames the process and keeps its counts");
  check(!strcmp(hd_table_thread_name(&t, 1000, 1010), "hwuiTask1") &&
            !strcmp(hd_table_thread_name(&t, 1000, 1000), "ample.app"),
        "a t line renames one thread and leaves the others");
  check(hd_table_thread_name(&t, 1000, 4242) == NULL, "an unnamed thread has no name");

  feed(&t, "c 1000 12 3\nx 1000\n");
  a = hd_table_app(&t, 1000);
  check(a && a->exited && a->work_periods == 12 && a->host_delayed == 3,
        "the final c lands, then x marks the app exited");
  check(hd_table_thread_name(&t, 1000, 1000) == NULL, "x drops the process's thread names");
  feed(&t, "d 1000 1000 6000000000 6001000000 1000000 10\nc 1000 99 99\nt 1000 1000 late\n");
  a = hd_table_app(&t, 1000);
  check(a && a->exited && a->delays == 3 && a->work_periods == 12 &&
            hd_table_thread_name(&t, 1000, 1000) == NULL,
        "a d, c or t after x changes nothing");
  feed(&t, "p 1000 pid.reused\n");
  a = hd_table_app(&t, 1000);
  check(a && !a->exited && !strcmp(a->name, "pid.reused") && a->delays == 0 && a->work_periods == 0,
        "a new p for an exited pid starts a new live row");

  feed(&t, "d 3000 3001 10 20000 5000 1\n");
  a = hd_table_app(&t, 3000);
  check(a && !strcmp(a->name, "?") && a->delays == 1, "a d before any p opens a row named ?");
  feed(&t, "p 3000 late.name\n");
  a = hd_table_app(&t, 3000);
  check(a && !strcmp(a->name, "late.name") && a->delays == 1, "the late p names it, counts kept");

  struct hd_table e;
  hd_table_init(&e);
  char line[64];
  for (int pid = 10; pid < 10 + 520; pid++) {
    snprintf(line, sizeof line, "p %d app%d\nc %d 1 0\nx %d\n", pid, pid, pid, pid);
    feed(&e, line);
  }
  check(e.n == HD_EXITED_KEEP && e.n_exited == HD_EXITED_KEEP && hd_table_app(&e, 10) == NULL &&
            hd_table_app(&e, 17) == NULL && hd_table_app(&e, 18) != NULL &&
            hd_table_app(&e, 529) != NULL,
        "520 exits leave the newest 512 (%zu rows)", e.n);
  feed(&e, "p 9000 live\n");
  check(hd_table_app(&e, 9000) && e.n == HD_EXITED_KEEP + 1, "live rows are never dropped");
  hd_table_free(&e);
  hd_table_free(&t);
}

// check the dumpsys text of an empty and a filled table
static void test_dump(void) {
  struct hd_table t;
  hd_table_init(&t);
  size_t len;
  char* s = hd_table_dump(&t, false, &len);
  const char* empty = "rhizo host delay: connected=no\n"
                      "pid\tprocess\twork_periods\thost_delayed\tdelays\theld_us\tstate\n";
  check(s && len == strlen(empty) && !memcmp(s, empty, len), "dumpsys text of an empty table");
  free(s);
  feed(&t, "p 2000 system_server\nt 2000 2001 Binder:2000_1\n"
           "d 2000 2001 5200000000 5201000999 1000999 3\nc 2000 4 1\n"
           "p 1000 com.example.app\nd 1000 1000 10 20 10 1\nc 1000 12 3\nx 1000\n");
  s = hd_table_dump(&t, true, &len);
  const char* want = "rhizo host delay: connected=yes\n"
                     "pid\tprocess\twork_periods\thost_delayed\tdelays\theld_us\tstate\n"
                     "1000\tcom.example.app\t12\t3\t1\t0\texited\n"
                     "2000\tsystem_server\t4\t1\t1\t1000\tlive\n";
  check(s && len == strlen(want) && !memcmp(s, want, len),
        "dumpsys text is byte-exact, sorted by pid, held_us rounded down per record");
  if (s && memcmp(s, want, len)) fprintf(stderr, "got:\n%.*s", (int)len, s);
  free(s);
  hd_table_free(&t);
}

struct packets {
  uint8_t* bytes[512];
  size_t len[512];
  size_t n;
};

// copy a packet into the packet list
static void keep(void* arg, const uint8_t* body, size_t len) {
  struct packets* p = arg;
  if (p->n == 512) abort();
  p->bytes[p->n] = malloc(len);
  memcpy(p->bytes[p->n], body, len);
  p->len[p->n++] = len;
}

// free all of the stored packets
static void free_packets(struct packets* p) {
  for (size_t i = 0; i < p->n; i++) free(p->bytes[i]);
  p->n = 0;
}

// decode a varint from a buffer
static bool varint(const uint8_t* b, size_t len, size_t* i, uint64_t* out) {
  uint64_t v = 0;
  for (int shift = 0; *i < len && shift < 64; shift += 7) {
    uint8_t c = b[(*i)++];
    v |= (uint64_t)(c & 0x7f) << shift;
    if (!(c & 0x80)) {
      *out = v;
      return true;
    }
  }
  return false;
}

// parse the top-level fields of a packet body
static bool top_fields(const uint8_t* b, size_t len, uint64_t* ts, uint64_t* clock, int* payload) {
  size_t i = 0;
  *ts = *clock = 0;
  *payload = 0;
  while (i < len) {
    uint64_t tag, v;
    if (!varint(b, len, &i, &tag)) return false;
    unsigned field = (unsigned)(tag >> 3), wt = tag & 7;
    if (wt == 0) {
      if (!varint(b, len, &i, &v)) return false;
      if (field == 8) *ts = v;
      if (field == 58) *clock = v;
    } else if (wt == 2) {
      if (!varint(b, len, &i, &v) || i + v > len) return false;
      if (field == 60 || field == 11) *payload = (int)field;
      i += v;
    } else {
      return false;
    }
  }
  return true;
}

// count the packets carrying a payload type
static size_t count_payload(const struct packets* p, int payload) {
  size_t n = 0;
  for (size_t i = 0; i < p->n; i++) {
    uint64_t ts, clock;
    int pl;
    if (top_fields(p->bytes[i], p->len[i], &ts, &clock, &pl) && pl == payload) n++;
  }
  return n;
}

// check all of the packets' timestamp, clock and payload
static bool every_packet_stamped(const struct packets* p) {
  for (size_t i = 0; i < p->n; i++) {
    uint64_t ts, clock;
    int pl;
    if (!top_fields(p->bytes[i], p->len[i], &ts, &clock, &pl) || ts == 0 || clock != 6 || !pl)
      return false;
  }
  return p->n > 0;
}

// feed a line to each instance
static void line_to_ordered(struct hd_table* t, struct hd_incr* seen[], struct packets* out[],
                            int n, const char* text, uint64_t now, bool wrong_order) {
  struct hd_line l;
  if (!hd_parse_line(text, strlen(text), &l)) return;
  if (!wrong_order)
    for (int i = 0; i < n; i++) {
      hd_emit_baseline(t, seen[i], now, keep, out[i]);
      hd_emit_baseline_pid(t, seen[i], l.pid, now, keep, out[i]);
    }
  bool applied = hd_table_apply(t, &l);
  if (wrong_order)
    for (int i = 0; i < n; i++) hd_emit_baseline(t, seen[i], now, keep, out[i]);
  if (!applied) return;
  for (int i = 0; i < n; i++) hd_emit_line(t, seen[i], &l, now, keep, out[i]);
}

// apply a line to the table and emit its packets
static void line_to(struct hd_table* t, struct hd_incr* seen[], struct packets* out[], int n,
                    const char* text, uint64_t now) {
  line_to_ordered(t, seen, out, n, text, now, false);
}

// append a varint to a buffer
static void put_varint(uint8_t* b, size_t* n, uint64_t v) {
  while (v >= 0x80) {
    b[(*n)++] = (uint8_t)(v | 0x80);
    v >>= 7;
  }
  b[(*n)++] = (uint8_t)v;
}

// write a Trace.packet to f
static void trace_packet(FILE* f, const uint8_t* body, size_t len, uint32_t seq) {
  uint8_t hdr[16], tail[8];
  size_t hn = 0, tn = 0;
  tail[tn++] = 10 << 3;
  put_varint(tail, &tn, seq);
  hdr[hn++] = (1 << 3) | 2;
  put_varint(hdr, &hn, len + tn);
  fwrite(hdr, 1, hn, f);
  fwrite(body, 1, len, f);
  fwrite(tail, 1, tn, f);
}

// encode a ClockSnapshot clock entry
static size_t clock_msg(uint8_t* b, uint32_t id, uint64_t ts) {
  uint8_t inner[24];
  size_t in = 0, n = 0;
  inner[in++] = 1 << 3;
  put_varint(inner, &in, id);
  inner[in++] = 2 << 3;
  put_varint(inner, &in, ts);
  b[n++] = (1 << 3) | 2;
  b[n++] = (uint8_t)in;
  memcpy(b + n, inner, in);
  return n + in;
}

// write a ClockSnapshot packet to f
static void clock_snapshot(FILE* f) {
  uint8_t snap[64], body[80];
  size_t sn = 0, bn = 0;
  sn += clock_msg(snap + sn, 6, 5000000000ull);
  sn += clock_msg(snap + sn, 3, 4900000000ull);
  snap[sn++] = 2 << 3;
  snap[sn++] = 6;
  body[bn++] = (6 << 3) | 2;
  body[bn++] = (uint8_t)sn;
  memcpy(body + bn, snap, sn);
  trace_packet(f, body, bn + sn, 1);
}

// return the path of the trace processor binary
static const char* tp_path(void) {
  static char path[512];
  const char* env = getenv("PERFETTO_TRACE_PROCESSOR");
  if (env && *env) return env;
  snprintf(path, sizeof path, "%s/.local/share/perfetto-tools/trace_processor",
           getenv("HOME") ? getenv("HOME") : "");
  return path;
}

// run sql on the trace with trace_processor
static char* query(const char* trace, const char* sql) {
  char sqlfile[] = "/tmp/hd-selftest-sql-XXXXXX";
  int fd = mkstemp(sqlfile);
  if (fd < 0) return NULL;
  ssize_t w = write(fd, sql, strlen(sql));
  close(fd);
  if (w != (ssize_t)strlen(sql)) return NULL;
  char cmd[1024];
  snprintf(cmd, sizeof cmd, "'%s' -q '%s' '%s' 2>/dev/null", tp_path(), sqlfile, trace);
  FILE* p = popen(cmd, "r");
  char* out = calloc(1, 65536);
  size_t n = 0;
  char line[1024];
  int row = 0;
  while (p && out && fgets(line, sizeof line, p)) {
    if (row++ == 0) continue;
    for (char* c = line; *c; c++)
      if (*c != '"') out[n++] = *c;
  }
  if (!p || pclose(p) != 0) {
    free(out);
    unlink(sqlfile);
    return NULL;
  }
  unlink(sqlfile);
  return out;
}

// write the packets to a trace file
static void build_trace(char* path, const struct packets* p) {
  close(mkstemp(path));
  FILE* f = fopen(path, "wb");
  clock_snapshot(f);
  for (size_t i = 0; i < p->n; i++) trace_packet(f, p->bytes[i], p->len[i], 7);
  fclose(f);
}

// test the packets in trace_processor
static void test_trace(void) {
  struct hd_table t;
  hd_table_init(&t);
  struct hd_incr a = {0}, b = {0};
  struct packets pa = {0}, pb = {0};
  struct hd_incr* seen[2] = {&a, &b};
  struct packets* out[2] = {&pa, &pb};
  const int N = 2;

  line_to(&t, seen, out, N, "p 1000 com.example.app", 4900000000ull);
  line_to(&t, seen, out, N, "t 1000 1000 ample.app", 0);
  line_to(&t, seen, out, N, "t 1000 1010 RenderThread", 0);
  check(count_payload(&pa, 60) == 5 && count_payload(&pa, 11) == 4,
        "a p line writes only the pid's baseline (process and four counters at 0); t lines write nothing");
  line_to(&t, seen, out, N, "d 1000 1000 5000000000 5003000000 2500000 7", 5003000000ull);
  line_to(&t, seen, out, N, "d 1000 1010 5010000000 5012500000 2500000 8", 5012500000ull);
  line_to(&t, seen, out, N, "d 1000 1000 5100000000 5100600000 600000 9", 5100600000ull);
  check(count_payload(&pa, 60) == 8 && count_payload(&pb, 60) == 8 && count_payload(&pa, 11) == 16,
        "three records on two threads: eight descriptors (two threads, the process unnamed then named, four counters) and sixteen events per instance");
  line_to(&t, seen, out, N, "c 1000 9 2", 5500000000ull);
  line_to(&t, seen, out, N, "p 2000 system_server", 5150000000ull);
  line_to(&t, seen, out, N, "t 2000 2001 Binder:2000_1", 0);
  line_to(&t, seen, out, N, "d 2000 2001 5200000000 5201000999 1000999 3", 5201000999ull);
  line_to(&t, seen, out, N, "c 1000 12 3", 5600000000ull);
  line_to(&t, seen, out, N, "c 2000 4 1", 5600000000ull);
  line_to(&t, seen, out, N, "t 1000 1010 hwuiTask1", 0);
  line_to(&t, seen, out, N, "d 1000 1010 5300000000 5304000000 4000000 10", 5304000000ull);
  line_to(&t, seen, out, N, "x 1000", 0);
  size_t before = pa.n;
  line_to(&t, seen, out, N, "d 1000 1000 5400000000 5401000000 1000000 11", 5401000000ull);
  check(pa.n == before, "a record after x emits nothing");

  size_t desc_a = count_payload(&pa, 60);
  hd_incr_free(&a);
  line_to(&t, seen, out, N, "d 2000 2001 5500000000 5501000000 1000000 4", 5501000000ull);
  check(count_payload(&pa, 60) == desc_a + 11 && count_payload(&pb, 60) == desc_a,
        "a cleared instance gets its descriptors and a new baseline, the other instance does not");
  check(every_packet_stamped(&pa) && every_packet_stamped(&pb),
        "every packet carries a timestamp, timestamp_clock_id 6 and a payload");

  char path[] = "/tmp/hd-selftest-trace-XXXXXX";
  build_trace(path, &pb);

  char* r = query(path, "select count(*) from slice");
  check(r != NULL, "trace_processor runs on the encoded trace (%s)", tp_path());
  free(r);

  r = query(path,
            "select t.tid, p.pid, s.ts, s.dur, s.name, "
            "extract_arg(s.arg_set_id, 'debug.held_us') as held_us, "
            "extract_arg(s.arg_set_id, 'debug.work_period') as wp "
            "from slice s join thread_track tt on s.track_id = tt.id "
            "join thread t using(utid) left join process p using(upid) order by s.ts, t.tid");
  const char* want_slices =
      "1000,1000,5000000000,3000000,held off by the host,2500,7\n"
      "1010,1000,5010000000,2500000,held off by the host,2500,8\n"
      "1000,1000,5100000000,600000,held off by the host,600,9\n"
      "2001,2000,5200000000,1000999,held off by the host,1000,3\n"
      "1010,1000,5300000000,4000000,held off by the host,4000,10\n"
      "2001,2000,5500000000,1000000,held off by the host,1000,4\n";
  check(r && !strcmp(r, want_slices),
        "slices land on the threads' own tracks with exact ts, dur and args");
  if (r && strcmp(r, want_slices)) fprintf(stderr, "got:\n%s", r);
  free(r);

  r = query(path, "select t.tid, t.name from thread t where t.tid in (1000, 1010, 2001) order by t.tid");
  const char* want_threads = "1000,ample.app\n1010,hwuiTask1\n2001,Binder:2000_1\n";
  check(r && !strcmp(r, want_threads), "thread tracks carry Android's thread names, renames included");
  if (r && strcmp(r, want_threads)) fprintf(stderr, "got:\n%s", r);
  free(r);

  r = query(path,
            "select p.pid, p.name, ct.name, c.ts, cast(c.value as int) "
            "from counter c join process_counter_track ct on c.track_id = ct.id "
            "join process p using(upid) order by p.pid, ct.name, c.ts");
  const char* want_counters =
      "1000,com.example.app,rhizo held us,4900000000,0\n"
      "1000,com.example.app,rhizo held us,5003000000,2500\n"
      "1000,com.example.app,rhizo held us,5012500000,5000\n"
      "1000,com.example.app,rhizo held us,5100600000,5600\n"
      "1000,com.example.app,rhizo held us,5304000000,9600\n"
      "1000,com.example.app,rhizo host delays,4900000000,0\n"
      "1000,com.example.app,rhizo host delays,5003000000,1\n"
      "1000,com.example.app,rhizo host delays,5012500000,2\n"
      "1000,com.example.app,rhizo host delays,5100600000,3\n"
      "1000,com.example.app,rhizo host delays,5304000000,4\n"
      "1000,com.example.app,rhizo host-delayed work periods,4900000000,0\n"
      "1000,com.example.app,rhizo host-delayed work periods,5500000000,2\n"
      "1000,com.example.app,rhizo host-delayed work periods,5600000000,3\n"
      "1000,com.example.app,rhizo work periods,4900000000,0\n"
      "1000,com.example.app,rhizo work periods,5500000000,9\n"
      "1000,com.example.app,rhizo work periods,5600000000,12\n"
      "2000,system_server,rhizo held us,5150000000,0\n"
      "2000,system_server,rhizo held us,5201000999,1000\n"
      "2000,system_server,rhizo held us,5501000000,2000\n"
      "2000,system_server,rhizo host delays,5150000000,0\n"
      "2000,system_server,rhizo host delays,5201000999,1\n"
      "2000,system_server,rhizo host delays,5501000000,2\n"
      "2000,system_server,rhizo host-delayed work periods,5150000000,0\n"
      "2000,system_server,rhizo host-delayed work periods,5600000000,1\n"
      "2000,system_server,rhizo work periods,5150000000,0\n"
      "2000,system_server,rhizo work periods,5600000000,4\n";
  check(r && !strcmp(r, want_counters),
        "counters land on the process's counter tracks, named, with the last value current");
  if (r && strcmp(r, want_counters)) fprintf(stderr, "got:\n%s", r);
  free(r);

  r = query(path, "select count(*) from slice where name != 'held off by the host'");
  check(r && !strcmp(r, "0\n"), "no slice carries anything but the one name");
  free(r);

  unlink(path);
  free_packets(&pa);
  free_packets(&pb);
  hd_incr_free(&a);
  hd_incr_free(&b);
  hd_table_free(&t);
}

static const char* kFirstLast =
    "select p.pid, ct.name, "
    "(select cast(value as int) from counter where track_id = ct.id order by ts asc, id asc limit 1), "
    "(select cast(value as int) from counter where track_id = ct.id order by ts desc, id desc limit 1) "
    "from process_counter_track ct join process p using(upid) order by p.pid, ct.name";

// build a trace and run two queries
static bool baseline_scenario(bool wrong_order, char** counters, char** slices, struct hd_table* t) {
  hd_table_init(t);
  struct hd_incr x = {0};
  struct packets px = {0};
  struct hd_incr* sx[1] = {&x};
  struct packets* ox[1] = {&px};
  line_to(t, sx, ox, 0, "p 1000 com.example.app", 0);
  line_to(t, sx, ox, 0, "d 1000 1000 1000000000 1002000000 2000000 1", 0);
  line_to(t, sx, ox, 0, "d 1000 1000 1100000000 1102000000 2000000 2", 0);
  line_to(t, sx, ox, 0, "d 1000 1010 1200000000 1202001000 2000999 3", 0);
  line_to(t, sx, ox, 0, "c 1000 5 1", 0);
  line_to(t, sx, ox, 0, "p 2000 gone.app", 0);
  line_to(t, sx, ox, 0, "d 2000 2001 1300000000 1301000000 1000000 1", 0);
  line_to(t, sx, ox, 0, "x 2000", 0);
  check(px.n == 0, "with no instance nothing is written");
  line_to_ordered(t, sx, ox, 1, "d 1000 1000 6000000000 6003000000 3000000 6", 6003000000ull, wrong_order);
  line_to_ordered(t, sx, ox, 1, "d 1000 1010 6010000000 6012500000 2500000 7", 6012500000ull, wrong_order);
  line_to_ordered(t, sx, ox, 1, "c 1000 6 2", 6100000000ull, wrong_order);
  line_to_ordered(t, sx, ox, 1, "p 3000 new.app", 6500000000ull, wrong_order);
  line_to_ordered(t, sx, ox, 1, "d 3000 3001 7000000000 7001000000 1000000 1", 7001000000ull, wrong_order);
  line_to_ordered(t, sx, ox, 1, "d 3000 3001 7010000000 7012000000 2000000 2", 7012000000ull, wrong_order);
  char path[] = "/tmp/hd-selftest-base-XXXXXX";
  build_trace(path, &px);
  *counters = query(path, kFirstLast);
  *slices = query(path, "select p.pid, count(*), sum(extract_arg(s.arg_set_id, 'debug.held_us')) "
                        "from slice s join thread_track tt on s.track_id = tt.id "
                        "join thread t using(utid) left join process p using(upid) group by p.pid");
  unlink(path);
  free_packets(&px);
  hd_incr_free(&x);
  return *counters && *slices;
}

// test the baseline counter values
static void test_baseline(void) {
  struct hd_table t;
  char *counters = NULL, *slices = NULL;
  bool ran = baseline_scenario(false, &counters, &slices, &t);
  check(ran, "a trace that starts after three records still runs through trace_processor");
  const char* want =
      "1000,rhizo held us,6000,11500\n"
      "1000,rhizo host delays,3,5\n"
      "1000,rhizo host-delayed work periods,1,2\n"
      "1000,rhizo work periods,5,6\n"
      "2000,rhizo held us,1000,1000\n"
      "2000,rhizo host delays,1,1\n"
      "2000,rhizo host-delayed work periods,0,0\n"
      "2000,rhizo work periods,0,0\n"
      "3000,rhizo held us,0,3000\n"
      "3000,rhizo host delays,0,2\n"
      "3000,rhizo host-delayed work periods,0,0\n"
      "3000,rhizo work periods,0,0\n";
  check(counters && !strcmp(counters, want),
        "baseline: every process, exited ones too, gets its four counters at the pre-start totals");
  if (counters && strcmp(counters, want)) fprintf(stderr, "got:\n%s", counters);
  const struct hd_app* a = hd_table_app(&t, 1000);
  check(a && a->delays == 5 && a->held_us == 11500,
        "last counter values equal the table (dumpsys): delays 5, held_us 11500");
  check(slices && !strcmp(slices, "1000,2,5500\n3000,2,3000\n"),
        "last - first (5-3 delays, 11500-6000 held_us) equals the trace's records for pid 1000, and 0 to 2 for a process born after the start");
  free(counters);
  free(slices);
  hd_table_free(&t);

  char *wc = NULL, *ws = NULL;
  struct hd_table wt;
  bool wran = baseline_scenario(true, &wc, &ws, &wt);
  check(wran && wc && strncmp(wc, want, strlen("1000,rhizo held us,6000,11500\n")) != 0,
        "baseline after apply is caught: the first values already hold the first record");
  free(wc);
  free(ws);
  hd_table_free(&wt);
}

// run the selftest and report the result
int main(int argc, char** argv) {
  if (argc != 2 || strcmp(argv[1], "--selftest")) {
    fprintf(stderr, "usage: %s --selftest\n", argv[0]);
    return 2;
  }
  test_parser();
  test_table();
  test_dump();
  test_trace();
  test_baseline();
  if (g_fail) {
    printf("hd_selftest: %d FAILED\n", g_fail);
    return 1;
  }
  printf("hd_selftest: all checks passed\n");
  return 0;
}
