// logcat and kernel log writer for rhizo-sensors-service
#ifndef RHIZO_SENSORS_LOG_H
#define RHIZO_SENSORS_LOG_H

#include <string>

namespace rhizo::sensors {

void klogf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

void setLogHook(void (*hook)(const std::string& message));

}

#endif
