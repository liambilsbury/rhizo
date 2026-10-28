#ifndef RHIZO_C2VA_VENDOR_H
#define RHIZO_C2VA_VENDOR_H

// the virgl vendor check

#include <string.h>

#include <va/va.h>

namespace rhizo::c2va {

// return whether a VA vendor string names virgl
inline bool IsVirglVendor(const char* vendor) { return vendor && strstr(vendor, " for virgl") != nullptr; }

bool IsVirgl(VADisplay display);

}

#endif
