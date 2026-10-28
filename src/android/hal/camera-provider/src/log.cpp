#include "log.h"

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

#include <mutex>

#ifdef __ANDROID__
#include <android/log.h>
#endif

namespace rhizo::camera {

// write a message to kmsg and logcat as rhizo-camera
void klogf(const char* fmt, ...) {
  char msg[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof(msg), fmt, ap);
  va_end(ap);
#ifdef __ANDROID__
  __android_log_print(ANDROID_LOG_INFO, "rhizo-camera", "%s", msg);
  static std::once_flag once;
  static int kmsgFd = -1;
  std::call_once(once, [] { kmsgFd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC); });
  if (kmsgFd >= 0) dprintf(kmsgFd, "<5>rhizo-camera: %s\n", msg);
#else
  fprintf(stderr, "rhizo-camera: %s\n", msg);
#endif
}

}
