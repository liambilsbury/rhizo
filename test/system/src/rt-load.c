#define _GNU_SOURCE
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static volatile sig_atomic_t g_stop = 0;
// set the stop flag
static void on_term(int sig) { (void)sig; g_stop = 1; }

// return a timespec in nanoseconds
static long long ns(const struct timespec *t) { return t->tv_sec * 1000000000LL + t->tv_nsec; }

// run a periodic CPU load at SCHED_FIFO priority
int main(int argc, char **argv) {
  if (argc != 6) {
    fprintf(stderr, "usage: rt-load <cpu> <period_us> <runtime_us> <seconds> <prio 1-99>\n");
    return 2;
  }
  int cpu = atoi(argv[1]);
  long long period_ns = atoll(argv[2]) * 1000LL;
  long long runtime_ns = atoll(argv[3]) * 1000LL;
  long long seconds = atoll(argv[4]);
  int prio = atoi(argv[5]);
  if (period_ns <= 0 || runtime_ns < 0 || runtime_ns > period_ns || seconds <= 0 || prio < 1 || prio > 99) {
    fprintf(stderr, "rt-load: bad arguments (need 0 <= runtime_us <= period_us, seconds > 0, 1 <= prio <= 99)\n");
    return 2;
  }

  if (cpu >= 0) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof set, &set)) {
      perror("sched_setaffinity");
      return 1;
    }
  }

  struct sched_param sp = { .sched_priority = prio };
  if (sched_setscheduler(0, SCHED_FIFO, &sp)) {
    perror("sched_setscheduler(SCHED_FIFO)");
    return 1;
  }

  signal(SIGTERM, on_term);
  signal(SIGINT, on_term);

  struct timespec next;
  clock_gettime(CLOCK_MONOTONIC, &next);
  long long deadline_ns = ns(&next) + seconds * 1000000000LL;
  long long periods = 0;
  while (!g_stop) {
    long long period_start = ns(&next);
    if (period_start >= deadline_ns) break;

    long long spin_until = period_start + runtime_ns;
    struct timespec now;
    do {
      clock_gettime(CLOCK_MONOTONIC, &now);
    } while (ns(&now) < spin_until && !g_stop);

    long long next_ns = period_start + period_ns;
    next.tv_sec = next_ns / 1000000000LL;
    next.tv_nsec = next_ns % 1000000000LL;
    periods++;
    if (g_stop) break;
    clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
  }

  double duty = period_ns > 0 ? (double)runtime_ns / (double)period_ns : 0.0;
  printf("rt-load cpu=%d period_us=%lld runtime_us=%lld prio=%d periods=%lld duty=%.4f\n",
         cpu, period_ns / 1000, runtime_ns / 1000, prio, periods, duty);
  return 0;
}
