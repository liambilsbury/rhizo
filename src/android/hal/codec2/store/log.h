#ifndef RHIZO_C2STORE_LOG_H
#define RHIZO_C2STORE_LOG_H

namespace rhizo::c2store {

// write a message to kmsg and logcat as rhizo-codec2
void klogf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

}

#endif
