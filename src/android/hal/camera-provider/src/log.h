#ifndef RHIZO_CAMERA_LOG_H
#define RHIZO_CAMERA_LOG_H

namespace rhizo::camera {

void klogf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

}

#endif
