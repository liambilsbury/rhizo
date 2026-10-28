#ifndef RHIZO_C2_AOSP_ANDROID_MEDIA_SWCODEC_FLAGS_H
#define RHIZO_C2_AOSP_ANDROID_MEDIA_SWCODEC_FLAGS_H

// the aconfig package android.media.swcodec.flags

namespace android::media::swcodec::flags {

class flag_provider_interface {
 public:
  bool dataspace_v0_gralloc4() const { return true; }
};

inline constexpr flag_provider_interface kRhizoConstantFlags{};
inline const flag_provider_interface* const provider_ = &kRhizoConstantFlags;

inline bool dataspace_v0_gralloc4() { return true; }

}

#endif
