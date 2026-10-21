#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

// return a timespec in nanoseconds
static long long ns(const struct timespec *t) { return t->tv_sec * 1000000000LL + t->tv_nsec; }
// compare two long long values
static int cmp_ll(const void *a, const void *b) {
  long long x = *(const long long *)a, y = *(const long long *)b;
  return (x > y) - (x < y);
}

// measure wake-up lateness of a periodic task
int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: rt-victim <cpu> <period_us> <seconds>\n");
    return 2;
  }
  int cpu = atoi(argv[1]);
  long long period_ns = atoll(argv[2]) * 1000LL;
  long long seconds = atoll(argv[3]);
  if (period_ns <= 0 || seconds <= 0) {
    fprintf(stderr, "rt-victim: period_us and seconds must be positive\n");
    return 2;
  }
  long long n = seconds * 1000000000LL / period_ns;
  if (n < 1) n = 1;

  if (cpu >= 0) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof set, &set)) {
      perror("sched_setaffinity");
      return 1;
    }
  }

  long long *late_us = malloc((size_t)n * sizeof *late_us);
  long long *at_ns = malloc((size_t)n * sizeof *at_ns);
  if (!late_us || !at_ns) {
    fprintf(stderr, "rt-victim: out of memory for n=%lld samples\n", n);
    return 1;
  }

  struct timespec next;
  clock_gettime(CLOCK_MONOTONIC, &next);
  for (long long i = 0; i < n; i++) {
    long long deadline = ns(&next) + period_ns;
    next.tv_sec = deadline / 1000000000LL;
    next.tv_nsec = deadline % 1000000000LL;
    clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    late_us[i] = (ns(&now) - deadline) / 1000;
    at_ns[i] = deadline;
  }

  long long *sorted = malloc((size_t)n * sizeof *sorted);
  for (long long i = 0; i < n; i++) sorted[i] = late_us[i];
  qsort(sorted, (size_t)n, sizeof *sorted, cmp_ll);

  long long over1ms = 0, over5ms = 0;
  for (long long i = 0; i < n; i++) {
    over1ms += sorted[i] > 1000;
    over5ms += sorted[i] > 5000;
  }

  printf("rt-victim cpu=%d n=%lld p50_us=%lld p99_us=%lld p999_us=%lld max_us=%lld over1ms=%lld over5ms=%lld\n",
         cpu, n, sorted[n / 2], sorted[n * 99 / 100], sorted[n * 999 / 1000], sorted[n - 1], over1ms, over5ms);

  for (int k = 0; k < 10; k++) {
    long long best = -1;
    long long best_i = -1;
    for (long long i = 0; i < n; i++) {
      if (late_us[i] > best) { best = late_us[i]; best_i = i; }
    }
    if (best_i < 0) break;
    printf("late %lld at %.6f\n", best, (double)at_ns[best_i] / 1e9);
    late_us[best_i] = -1;
  }
  return 0;
}
