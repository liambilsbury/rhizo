#define _GNU_SOURCE
#include <stdarg.h>
#include <stdint.h>
#include <errno.h>
#include <linux/bpf.h>

#if defined(__x86_64__)
#define SYS_bpf_nr 321
#elif defined(__aarch64__)
#define SYS_bpf_nr 280
#else
#error "rhizo_bpf_preload: only x86_64 and aarch64 wired up (matches the two host architectures this project builds for)"
#endif

#if defined(__x86_64__)
// make a six-argument x86_64 syscall
static long raw_syscall6(long nr, long a1, long a2, long a3, long a4, long a5,
                          long a6) {
  long ret;
  register long r10 __asm__("r10") = a4;
  register long r8 __asm__("r8") = a5;
  register long r9 __asm__("r9") = a6;
  __asm__ __volatile__("syscall"
                        : "=a"(ret)
                        : "a"(nr), "D"(a1), "S"(a2), "d"(a3), "r"(r10),
                          "r"(r8), "r"(r9)
                        : "rcx", "r11", "memory");
  return ret;
}
#elif defined(__aarch64__)
// make a six-argument aarch64 syscall
static long raw_syscall6(long nr, long a1, long a2, long a3, long a4, long a5,
                          long a6) {
  register long x0 __asm__("x0") = a1;
  register long x1 __asm__("x1") = a2;
  register long x2 __asm__("x2") = a3;
  register long x3 __asm__("x3") = a4;
  register long x4 __asm__("x4") = a5;
  register long x5 __asm__("x5") = a6;
  register long x8 __asm__("x8") = nr;
  __asm__ __volatile__("svc #0"
                        : "+r"(x0)
                        : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x8)
                        : "memory");
  return x0;
}
#endif

// fail bpf id enumeration with ENOENT
long syscall(long number, ...) {
  va_list ap;
  va_start(ap, number);
  long a1 = va_arg(ap, long);
  long a2 = va_arg(ap, long);
  long a3 = va_arg(ap, long);
  long a4 = va_arg(ap, long);
  long a5 = va_arg(ap, long);
  long a6 = va_arg(ap, long);
  va_end(ap);

  if (number == SYS_bpf_nr) {
    unsigned int cmd = (unsigned int)a1;
    if (cmd == BPF_PROG_GET_NEXT_ID || cmd == BPF_MAP_GET_NEXT_ID ||
        cmd == BPF_LINK_GET_NEXT_ID || cmd == BPF_BTF_GET_NEXT_ID) {
      errno = ENOENT;
      return -1;
    }
  }

  long ret = raw_syscall6(number, a1, a2, a3, a4, a5, a6);
  if (ret < 0) {
    errno = (int)-ret;
    return -1;
  }
  return ret;
}
