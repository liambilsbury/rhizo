#ifndef RHIZO_C2_AOSP_ANDROID_MEDIA_CODEC_H
#define RHIZO_C2_AOSP_ANDROID_MEDIA_CODEC_H

// the aconfig package android.media.codec

namespace android::media::codec {

class flag_provider_interface {
 public:
  bool dataspace_v0_partial() const { return true; }
  bool input_surface_throttle() const { return true; }
};

inline constexpr flag_provider_interface kRhizoConstantFlags{};
inline const flag_provider_interface* const provider_ = &kRhizoConstantFlags;

inline bool dataspace_v0_partial() { return true; }
inline bool input_surface_throttle() { return true; }

}

#endif
