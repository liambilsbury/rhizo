#ifndef RHIZO_C2_AOSP_SYS_SYSTEM_PROPERTIES_H
#define RHIZO_C2_AOSP_SYS_SYSTEM_PROPERTIES_H

// declare the bionic property serial calls

#include_next <sys/system_properties.h>

#include <stdint.h>

__BEGIN_DECLS

uint32_t __system_property_area_serial(void);
uint32_t __system_property_serial(const prop_info* _Nonnull __pi);

__END_DECLS

#endif
