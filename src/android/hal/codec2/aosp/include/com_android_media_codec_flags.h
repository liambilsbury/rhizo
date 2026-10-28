#ifndef RHIZO_C2_AOSP_COM_ANDROID_MEDIA_CODEC_FLAGS_H
#define RHIZO_C2_AOSP_COM_ANDROID_MEDIA_CODEC_FLAGS_H

// the aconfig package com.android.media.codec.flags

namespace com::android::media::codec::flags {

class flag_provider_interface {
 public:
  bool aidl_hal() const { return true; }
  bool large_audio_frame() const { return true; }
};

inline constexpr flag_provider_interface kRhizoConstantFlags{};
inline const flag_provider_interface* const provider_ = &kRhizoConstantFlags;

inline bool aidl_hal() { return true; }
inline bool large_audio_frame() { return true; }

}

#endif
