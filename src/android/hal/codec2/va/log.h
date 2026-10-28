#ifndef RHIZO_C2VA_LOG_H
#define RHIZO_C2VA_LOG_H

// the rhizo-c2va log, to logcat or stderr

#include <va/va.h>

namespace rhizo::c2va {

enum class LogTarget { kLogcat, kStderr, kNone };

void SetLogTarget(LogTarget target);

void Logf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void LogErrorf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

// route libva's error and info callbacks to the log
void RouteVaMessages(VADisplay display);

}

#endif
