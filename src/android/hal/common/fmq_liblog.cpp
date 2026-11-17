#include <android/log.h>
#include <log/log.h>

#include <string>

namespace android {
namespace hardware {
namespace details {

namespace {
constexpr const char* kTag = "FMQ";
}

// call __android_log_assert when exp is false
void check(bool exp, const char* message) {
  if (!exp) __android_log_assert(nullptr, kTag, "check failed (%s)", message);
}

// write message to liblog at ANDROID_LOG_ERROR
void logError(const std::string& message) {
  __android_log_write(ANDROID_LOG_ERROR, kTag, message.c_str());
}

// call android_errorWriteLog with tag and info
void errorWriteLog(int tag, const char* info) {
  android_errorWriteLog(tag, info);
}

}
}
}
