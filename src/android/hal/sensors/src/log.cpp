// logcat and kernel log writer for rhizo-sensors-service
#include "log.h"

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

#include <atomic>
#include <mutex>

#ifdef __ANDROID__
#include <android/log.h>
#endif

namespace rhizo::sensors {

namespace {
std::atomic<void (*)(const std::string&)> gHook{nullptr};
}

// set the hook that receives each message
void setLogHook(void (*hook)(const std::string& message)) {
  gHook.store(hook);
}

// write a formatted message to /dev/kmsg and logcat
void klogf(const char* fmt, ...) {
  char msg[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof(msg), fmt, ap);
  va_end(ap);
#ifdef __ANDROID__
  __android_log_print(ANDROID_LOG_INFO, "rhizo-sensors", "%s", msg);
  static std::once_flag once;
  static int kmsgFd = -1;
  std::call_once(once, [] { kmsgFd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC); });
  if (kmsgFd >= 0) dprintf(kmsgFd, "<5>rhizo-sensors: %s\n", msg);
#else
  fprintf(stderr, "rhizo-sensors: %s\n", msg);
#endif
  auto hook = gHook.load();
  if (hook) hook(msg);
}

}
