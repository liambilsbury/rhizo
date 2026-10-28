// fail the libcap calls minijail links with ENOSYS

#include <errno.h>
#include <stddef.h>

#include <sys/capability.h>

cap_t cap_get_proc(void) {
  errno = ENOSYS;
  return NULL;
}

int cap_set_proc(cap_t caps) {
  (void)caps;
  errno = ENOSYS;
  return -1;
}

int cap_clear(cap_t caps) {
  (void)caps;
  errno = ENOSYS;
  return -1;
}

int cap_set_flag(cap_t caps, cap_flag_t set, int count, const cap_value_t* values, cap_flag_value_t raise) {
  (void)caps;
  (void)set;
  (void)count;
  (void)values;
  (void)raise;
  errno = ENOSYS;
  return -1;
}

int cap_free(void* object) {
  (void)object;
  return 0;
}
