#ifndef RHIZO_C2_AOSP_LINUX_SECUREBITS_H
#define RHIZO_C2_AOSP_LINUX_SECUREBITS_H

// add the Linux 6.14 exec-restriction secure bits

#include_next <linux/securebits.h>

#ifndef SECURE_EXEC_RESTRICT_FILE
#define SECURE_EXEC_RESTRICT_FILE 8
#define SECURE_EXEC_RESTRICT_FILE_LOCKED 9
#define SECBIT_EXEC_RESTRICT_FILE (issecure_mask(SECURE_EXEC_RESTRICT_FILE))
#define SECBIT_EXEC_RESTRICT_FILE_LOCKED (issecure_mask(SECURE_EXEC_RESTRICT_FILE_LOCKED))
#define SECURE_EXEC_DENY_INTERACTIVE 10
#define SECURE_EXEC_DENY_INTERACTIVE_LOCKED 11
#define SECBIT_EXEC_DENY_INTERACTIVE (issecure_mask(SECURE_EXEC_DENY_INTERACTIVE))
#define SECBIT_EXEC_DENY_INTERACTIVE_LOCKED (issecure_mask(SECURE_EXEC_DENY_INTERACTIVE_LOCKED))
#undef SECURE_ALL_BITS
#define SECURE_ALL_BITS                                                                               \
  (issecure_mask(SECURE_NOROOT) | issecure_mask(SECURE_NO_SETUID_FIXUP) | issecure_mask(SECURE_KEEP_CAPS) | \
   issecure_mask(SECURE_NO_CAP_AMBIENT_RAISE) | issecure_mask(SECURE_EXEC_RESTRICT_FILE) |               \
   issecure_mask(SECURE_EXEC_DENY_INTERACTIVE))
#endif

#endif
