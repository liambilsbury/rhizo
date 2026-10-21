#include <android/log.h>
#include <log/log.h>

#include <string>

namespace android {
namespace hardware {
namespace details {

namespace {
constexpr const char* kTag = "FMQ";
}

// abort on a false expression
void check(bool exp, const char* message) {
  if (!exp) __android_log_assert(nullptr, kTag, "Check failed: %s", message);
}

// write the message to liblog
void logError(const std::string& message) {
  __android_log_write(ANDROID_LOG_ERROR, kTag, message.c_str());
}

// forward the error log entry to android_errorWriteLog
void errorWriteLog(int tag, const char* info) {
  android_errorWriteLog(tag, info);
}

}
}
}
