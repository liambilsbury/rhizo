#ifndef RHIZO_C2_AOSP_SYS_CAPABILITY_H
#define RHIZO_C2_AOSP_SYS_CAPABILITY_H

// declare the POSIX.1e capability calls

#include <linux/capability.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct _cap_struct* cap_t;
typedef int cap_value_t;
typedef enum { CAP_EFFECTIVE = 0, CAP_PERMITTED = 1, CAP_INHERITABLE = 2 } cap_flag_t;
typedef enum { CAP_CLEAR = 0, CAP_SET = 1 } cap_flag_value_t;

cap_t cap_get_proc(void);
int cap_set_proc(cap_t caps);
int cap_clear(cap_t caps);
int cap_set_flag(cap_t caps, cap_flag_t set, int count, const cap_value_t* values, cap_flag_value_t raise);
int cap_free(void* object);

#ifdef __cplusplus
}
#endif

#endif
