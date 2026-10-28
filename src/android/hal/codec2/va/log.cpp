#include "va/log.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include <atomic>

#ifdef __ANDROID__
#include <android/log.h>
#endif

namespace rhizo::c2va {

namespace {

std::atomic<LogTarget> g_target{LogTarget::kLogcat};

void Write(bool error, const char* fmt, va_list ap) {
  LogTarget target = g_target.load();
  if (target == LogTarget::kNone) return;
  char msg[768];
  vsnprintf(msg, sizeof(msg), fmt, ap);
  size_t n = strlen(msg);
  while (n > 0 && msg[n - 1] == '\n') msg[--n] = '\0';
#ifdef __ANDROID__
  if (target == LogTarget::kLogcat) {
    __android_log_write(error ? ANDROID_LOG_ERROR : ANDROID_LOG_INFO, "rhizo-c2va", msg);
    return;
  }
#endif
  fprintf(stderr, "rhizo-c2va: %s%s\n", error ? "error: " : "", msg);
}

void VaError(void*, const char* message) { LogErrorf("libva: %s", message); }
void VaInfo(void*, const char* message) { Logf("libva: %s", message); }

}

void SetLogTarget(LogTarget target) { g_target.store(target); }

void Logf(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  Write(false, fmt, ap);
  va_end(ap);
}

void LogErrorf(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  Write(true, fmt, ap);
  va_end(ap);
}

void RouteVaMessages(VADisplay display) {
  vaSetErrorCallback(display, VaError, nullptr);
  vaSetInfoCallback(display, VaInfo, nullptr);
}

}
