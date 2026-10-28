#ifndef RHIZO_C2VA_RUNTIME_H
#define RHIZO_C2VA_RUNTIME_H

// the VA runtime under the Codec2 components

#include <stddef.h>
#include <stdint.h>

#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <va/va.h>

#include "va/core.h"
#include "va/vendor.h"

namespace rhizo::c2va {

// a VA display, terminated with its last reference
class Display {
 public:
  ~Display();
  Display(const Display&) = delete;
  Display& operator=(const Display&) = delete;

  VADisplay va() const { return va_; }
  // return the vaQueryVendorString value
  const std::string& vendor() const { return vendor_; }
  int major() const { return major_; }
  int minor() const { return minor_; }

 private:
  friend class VaDevice;
  Display() = default;
  VADisplay va_ = nullptr;
  int fd_ = -1;
  std::string vendor_;
  int major_ = 0;
  int minor_ = 0;
};

// the render node, opened per session
class VaDevice {
 public:
  static VaDevice& Get();

  void SetNode(const std::string& path);
  // set the node from an inherited descriptor
  void SetFd(int fd);

  // open a separate display for the caller
  std::shared_ptr<Display> Open(Status* status);
  // return the display shared by the capability query and the probe
  std::shared_ptr<Display> Acquire(Status* status);
  int OpenCount();
  bool IsOpen();

 private:
  VaDevice() = default;
  std::shared_ptr<Display> OpenLocked(Status* status);
  std::mutex mutex_;
  std::string node_ = "/dev/dri/renderD128";
  int inherited_fd_ = -1;
  std::weak_ptr<Display> shared_;
};

enum class Codec { kAvc, kHevc, kVp9, kAv1 };
enum class Kind { kDecoder, kEncoder };

// a c2.rhizo.* component as the running driver offers it
struct ComponentCaps {
  std::string name;
  std::string mime;
  Codec codec;
  Kind kind;
  std::vector<VAProfile> va_profiles;
  std::vector<uint32_t> bit_depths;
  uint32_t min_width;
  uint32_t min_height;
  uint32_t max_width;
  uint32_t max_height;
  uint32_t coded_min_width = 0, coded_min_height = 0;
  uint32_t max_instances;
  uint32_t va_rate_controls;
  bool min_from_driver;
  bool imports_yuv_dmabuf = false;
  std::string functional = "unchecked";
};

// a dropped component, or its dropped 10-bit profiles
struct DroppedComponent {
  std::string name;
  std::vector<VAProfile> va_profiles;
  std::vector<uint32_t> bit_depths;
  std::string why;
};

// return the components with a VA config that creates
std::vector<ComponentCaps> QueryComponents(VADisplay display);
std::vector<ComponentCaps> QueryComponents(VaDevice& device, Status* status = nullptr);

// read the limits cached for a component on an open display
bool ComponentLimits(VADisplay display, Codec codec, Kind kind, ComponentCaps* out);
void ForgetComponents(VADisplay display);
bool CodecForProfile(VAProfile profile, Codec* codec);

const char* ProfileName(VAProfile profile);

// test once whether the driver's VPP draws NV12 to RGBA
bool VppDraws(VADisplay display);
// format the components as the probe's one-line JSON
std::string ComponentsJson(const std::string& driver, int va_major, int va_minor,
                           const std::vector<ComponentCaps>& components,
                           const std::vector<DroppedComponent>& dropped = {},
                           const std::string& measurements = "");

// a dmabuf-backed image as gralloc describes it
struct DmabufImage {
  int fd;
  uint32_t drm_fourcc;
  uint64_t modifier;
  uint32_t width;
  uint32_t height;
  int num_planes;
  uint32_t pitches[4];
  uint32_t offsets[4];
  int num_objects;
  int object_fds[4];
  uint32_t plane_object[4];
};

struct Plane {
  uint8_t* data;
  int32_t row_stride;
  int32_t pixel_stride;
};

// any 4:2:0 layout
struct YuvDest {
  Plane y;
  Plane cb;
  Plane cr;
  int32_t width;
  int32_t height;
  int32_t bytes_per_sample = 1;
};

struct ConstPlane {
  const uint8_t* data;
  int32_t row_stride;
  int32_t pixel_stride;
};

// any 8-bit 4:2:0 layout
struct YuvSrc {
  ConstPlane y;
  ConstPlane cb;
  ConstPlane cr;
  int32_t width;
  int32_t height;
};

// bytes R, G, B, A
struct RgbaSrc {
  const uint8_t* data;
  int32_t row_stride;
  int32_t width;
  int32_t height;
};

// a decoded picture, valid until ReleaseFrame or session destruction
struct Frame {
  VASurfaceID surface;
  uint64_t tag;
  Rect crop;
  ColorInfo color;
  uint32_t fourcc;
  uint32_t bit_depth;
  uint32_t width;
  uint32_t height;
};

struct DecodeCallbacks {
  std::function<void(const Frame& frame)> output;
  std::function<void(uint64_t tag)> skip;
  std::function<void(const StreamInfo& info)> stream_changed;
};

using DecoderCoreFactory = std::function<std::unique_ptr<DecoderCore>(DecoderHost* host)>;

// a VA decode session hosting a decoder core
class DecodeSession final : public DecoderHost {
 public:
  // create a session for the codec's linked core
  static std::unique_ptr<DecodeSession> Create(Codec codec, DecodeCallbacks callbacks, Status* status,
                                               VaDevice& device = VaDevice::Get());
  static std::unique_ptr<DecodeSession> CreateWithCore(const DecoderCoreFactory& factory,
                                                       DecodeCallbacks callbacks, Status* status,
                                                       VaDevice& device = VaDevice::Get());
  ~DecodeSession() override;

  // decode an access unit framed per core.h
  Status Decode(const uint8_t* data, size_t size, uint64_t tag, bool codec_config);
  // output the owed pictures
  Status Drain();
  // skip the pending tags
  void Reset();

  // convert a frame to an RGBA dmabuf in the declared colour
  Status ToRgba(const Frame& frame, const DmabufImage& dst, const ColorInfo& color);
  // convert a frame to an RGBA, RGBX, BGRA or BGRX surface
  Status ToRgbaSurface(const Frame& frame, VASurfaceID surface, uint32_t va_fourcc, uint32_t width, uint32_t height,
                       const ColorInfo& color);
  Status ToYuv(const Frame& frame, const YuvDest& dst);
  void ReleaseFrame(const Frame& frame);

  // set the minimum picture size later Configure calls allocate
  void SetMaxPictureSize(uint32_t width, uint32_t height);

  // return the current stream info
  StreamInfo stream_info();
  uint32_t pool_size();

  VADisplay display() override;
  Status Configure(const StreamInfo& info, VAContextID* context) override;
  void SurfaceSize(uint32_t* width, uint32_t* height) override;
  Status AcquireSurface(VASurfaceID* surface) override;
  void ReleaseSurface(VASurfaceID surface) override;
  void Output(VASurfaceID surface, uint64_t tag, const Rect& crop, const ColorInfo& color) override;
  void Skip(uint64_t tag) override;

  static constexpr uint32_t kOutputSlack = 4;

  struct State;

 private:
  DecodeSession() = default;
  std::unique_ptr<State> s_;
};

struct EncodeCallbacks {
  std::function<void(const uint8_t* data, size_t size, uint64_t tag, int64_t pts, bool keyframe, bool codec_config)>
      output;
};

using EncoderCoreFactory =
    std::function<std::unique_ptr<EncoderCore>(EncoderHost* host, const EncoderConfig& config, Status* status)>;

enum class RgbaPath {
  kUnknown,
  kVpp,
  kCpu,
  kUnsupported,
};

// a VA encode session hosting an encoder core
class EncodeSession final : public EncoderHost {
 public:
  // create a session with the config clamped to the driver's limits
  static std::unique_ptr<EncodeSession> Create(Codec codec, const EncoderConfig& config, EncodeCallbacks callbacks,
                                               Status* status, VaDevice& device = VaDevice::Get());
  static std::unique_ptr<EncodeSession> CreateWithCore(const EncoderCoreFactory& factory, Codec codec,
                                                       const EncoderConfig& config, EncodeCallbacks callbacks,
                                                       Status* status, VaDevice& device = VaDevice::Get());
  ~EncodeSession() override;

  Status Encode(const YuvSrc& src, uint64_t tag, int64_t pts, bool keyframe);
  // encode an RGBA source converted on the CPU
  Status Encode(const RgbaSrc& src, uint64_t tag, int64_t pts, bool keyframe);
  // encode an imported dmabuf
  Status Encode(const DmabufImage& src, uint64_t tag, int64_t pts, bool keyframe);
  // return whether Encode(DmabufImage) imports a YUV dmabuf
  static bool ImportsYuvDmabuf(VADisplay display);
  Status Drain();
  Status SetBitrate(uint32_t bitrate);

  // return the clamped config
  const EncoderConfig& config() const;
  RgbaPath rgba_path() const;

  VADisplay display() override;
  Status Configure(const EncoderConfig& config, VAConfigAttrib* attribs, int num_attribs, uint32_t align_width,
                   uint32_t align_height, VAContextID* context) override;
  Status AcquireReconSurface(VASurfaceID* surface) override;
  void ReleaseReconSurface(VASurfaceID surface) override;
  void Output(const uint8_t* data, size_t size, uint64_t tag, int64_t pts, bool keyframe,
              bool codec_config) override;

  static constexpr uint32_t kMaxInputSurfaces = 16;
  static constexpr uint32_t kMaxReconSurfaces = 32;

  struct State;

 private:
  EncodeSession() = default;
  std::unique_ptr<State> s_;
};

}

#endif
