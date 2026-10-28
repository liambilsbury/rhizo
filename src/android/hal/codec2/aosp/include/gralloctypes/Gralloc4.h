#ifndef RHIZO_C2_AOSP_GRALLOCTYPES_GRALLOC4_H
#define RHIZO_C2_AOSP_GRALLOCTYPES_GRALLOC4_H

// the ExtendableType helpers, from AOSP's Gralloc4.cpp (Apache-2.0, The Android Open Source Project)

#include <cstring>
#include <sstream>
#include <string>

#include <aidl/android/hardware/graphics/common/ChromaSiting.h>
#include <aidl/android/hardware/graphics/common/Compression.h>
#include <aidl/android/hardware/graphics/common/ExtendableType.h>
#include <aidl/android/hardware/graphics/common/Interlaced.h>
#include <aidl/android/hardware/graphics/common/PlaneLayoutComponentType.h>

#define GRALLOC4_STANDARD_METADATA_TYPE "android.hardware.graphics.common.StandardMetadataType"
#define GRALLOC4_STANDARD_CHROMA_SITING "android.hardware.graphics.common.ChromaSiting"
#define GRALLOC4_STANDARD_COMPRESSION "android.hardware.graphics.common.Compression"
#define GRALLOC4_STANDARD_INTERLACED "android.hardware.graphics.common.Interlaced"
#define GRALLOC4_STANDARD_PLANE_LAYOUT_COMPONENT_TYPE "android.hardware.graphics.common.PlaneLayoutComponentType"

namespace android::gralloc4 {

using ::aidl::android::hardware::graphics::common::ChromaSiting;
using ::aidl::android::hardware::graphics::common::Compression;
using ::aidl::android::hardware::graphics::common::ExtendableType;
using ::aidl::android::hardware::graphics::common::Interlaced;
using ::aidl::android::hardware::graphics::common::PlaneLayoutComponentType;

inline bool isStandardCompression(const ExtendableType& compression) {
  return !std::strncmp(compression.name.c_str(), GRALLOC4_STANDARD_COMPRESSION, compression.name.size());
}

inline bool isStandardInterlaced(const ExtendableType& interlaced) {
  return !std::strncmp(interlaced.name.c_str(), GRALLOC4_STANDARD_INTERLACED, interlaced.name.size());
}

inline bool isStandardChromaSiting(const ExtendableType& chromaSiting) {
  return !std::strncmp(chromaSiting.name.c_str(), GRALLOC4_STANDARD_CHROMA_SITING, chromaSiting.name.size());
}

inline bool isStandardPlaneLayoutComponentType(const ExtendableType& planeLayoutComponentType) {
  return !std::strncmp(planeLayoutComponentType.name.c_str(), GRALLOC4_STANDARD_PLANE_LAYOUT_COMPONENT_TYPE,
                       planeLayoutComponentType.name.size());
}

inline Compression getStandardCompressionValue(const ExtendableType& compression) {
  return static_cast<Compression>(compression.value);
}

inline Interlaced getStandardInterlacedValue(const ExtendableType& interlaced) {
  return static_cast<Interlaced>(interlaced.value);
}

inline ChromaSiting getStandardChromaSitingValue(const ExtendableType& chromaSiting) {
  return static_cast<ChromaSiting>(chromaSiting.value);
}

inline PlaneLayoutComponentType getStandardPlaneLayoutComponentTypeValue(
    const ExtendableType& planeLayoutComponentType) {
  return static_cast<PlaneLayoutComponentType>(planeLayoutComponentType.value);
}

// "name#value" for a type outside the standard set
inline std::string nonStandardName(const ExtendableType& type) {
  std::ostringstream stream;
  stream << type.name << "#" << type.value;
  return stream.str();
}

inline std::string getCompressionName(const ExtendableType& compression) {
  if (!isStandardCompression(compression)) return nonStandardName(compression);
  switch (getStandardCompressionValue(compression)) {
    case Compression::NONE:
      return "None";
    case Compression::DISPLAY_STREAM_COMPRESSION:
      return "DisplayStreamCompression";
  }
  return "";
}

inline std::string getInterlacedName(const ExtendableType& interlaced) {
  if (!isStandardInterlaced(interlaced)) return nonStandardName(interlaced);
  switch (getStandardInterlacedValue(interlaced)) {
    case Interlaced::NONE:
      return "None";
    case Interlaced::TOP_BOTTOM:
      return "TopBottom";
    case Interlaced::RIGHT_LEFT:
      return "RightLeft";
  }
  return "";
}

inline std::string getChromaSitingName(const ExtendableType& chromaSiting) {
  if (!isStandardChromaSiting(chromaSiting)) return nonStandardName(chromaSiting);
  switch (getStandardChromaSitingValue(chromaSiting)) {
    case ChromaSiting::NONE:
      return "None";
    case ChromaSiting::UNKNOWN:
      return "Unknown";
    case ChromaSiting::SITED_INTERSTITIAL:
      return "SitedInterstitial";
    case ChromaSiting::COSITED_HORIZONTAL:
      return "CositedHorizontal";
    case ChromaSiting::COSITED_VERTICAL:
      return "CositedVertical";
    case ChromaSiting::COSITED_BOTH:
      return "CositedBoth";
  }
  return "";
}

inline std::string getPlaneLayoutComponentTypeName(const ExtendableType& planeLayoutComponentType) {
  if (!isStandardPlaneLayoutComponentType(planeLayoutComponentType)) {
    return nonStandardName(planeLayoutComponentType);
  }
  switch (getStandardPlaneLayoutComponentTypeValue(planeLayoutComponentType)) {
    case PlaneLayoutComponentType::Y:
      return "Y";
    case PlaneLayoutComponentType::CB:
      return "Cb";
    case PlaneLayoutComponentType::CR:
      return "Cr";
    case PlaneLayoutComponentType::R:
      return "R";
    case PlaneLayoutComponentType::G:
      return "G";
    case PlaneLayoutComponentType::B:
      return "B";
    case PlaneLayoutComponentType::RAW:
      return "RAW";
    case PlaneLayoutComponentType::A:
      return "A";
  }
  return "";
}

}  // namespace android::gralloc4

#endif
