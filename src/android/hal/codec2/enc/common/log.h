#ifndef RHIZO_C2VA_ENC_LOG_H
#define RHIZO_C2VA_ENC_LOG_H

// the encoder core's log

#include <stdarg.h>
#include <stdio.h>

#ifdef __ANDROID__
#include <android/log.h>
#endif

namespace rhizo::c2va {

// write a line to the runtime's log
void Logf(const char* fmt, ...) __attribute__((weak, format(printf, 1, 2)));

inline void EncLog(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
inline void EncLog(const char* fmt, ...) {
  char msg[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof(msg), fmt, ap);
  va_end(ap);
  if (&Logf != nullptr) {
    Logf("enc: %s", msg);
    return;
  }
#ifdef __ANDROID__
  __android_log_write(ANDROID_LOG_INFO, "rhizo-c2enc", msg);
#else
  fprintf(stderr, "rhizo-c2enc: %s\n", msg);
#endif
}

}

#endif
