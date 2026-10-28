#include <string.h>

#include <algorithm>
#include <functional>
#include <utility>
#include <vector>

#include "va/convert.h"
#include "va/log.h"
#include "va/runtime.h"
#include "va/vpp.h"

namespace rhizo::c2va {

std::unique_ptr<DecoderCore> CreateH264Decoder(DecoderHost* host) __attribute__((weak));
std::unique_ptr<DecoderCore> CreateHevcDecoder(DecoderHost* host) __attribute__((weak));
std::unique_ptr<DecoderCore> CreateVp9Decoder(DecoderHost* host) __attribute__((weak));
std::unique_ptr<DecoderCore> CreateAv1Decoder(DecoderHost* host) __attribute__((weak));

namespace {

DecoderCoreFactory CoreFactoryFor(Codec codec) {
  switch (codec) {
    case Codec::kAvc: return CreateH264Decoder ? DecoderCoreFactory(CreateH264Decoder) : nullptr;
    case Codec::kHevc: return CreateHevcDecoder ? DecoderCoreFactory(CreateHevcDecoder) : nullptr;
    case Codec::kVp9: return CreateVp9Decoder ? DecoderCoreFactory(CreateVp9Decoder) : nullptr;
    case Codec::kAv1: return CreateAv1Decoder ? DecoderCoreFactory(CreateAv1Decoder) : nullptr;
  }
  return nullptr;
}

struct PoolSurface {
  VASurfaceID id;
  uint32_t refs;
  bool retired;
};

}

struct DecodeSession::State {
  std::shared_ptr<Display> display;
  VADisplay dpy = nullptr;
  DecodeCallbacks cb;
  std::unique_ptr<DecoderCore> core;

  std::mutex mutex;
  StreamInfo info{};
  bool configured = false;
  uint32_t max_w = 0, max_h = 0;
  uint32_t surf_w = 0, surf_h = 0;
  uint32_t fourcc = VA_FOURCC_NV12;
  VAConfigID config = VA_INVALID_ID;
  VAContextID context = VA_INVALID_ID;
  std::vector<PoolSurface> surfaces;

  std::mutex image_mutex;
  VAImage image{};
  bool image_valid = false;

  std::mutex rgba_mutex;
  VAImage rgba{};
  bool rgba_valid = false;

  Vpp vpp;

  // map a frame's readback and pass it to use
  Status ReadFrame(const Frame& frame, const std::function<void(const SemiPlanar&)>& use);

  PoolSurface* Find(VASurfaceID id) {
    for (auto& s : surfaces) {
      if (s.id == id) return &s;
    }
    return nullptr;
  }

  // drop a reference on a pool surface
  void Unref(VASurfaceID id) {
    for (size_t i = 0; i < surfaces.size(); i++) {
      PoolSurface& s = surfaces[i];
      if (s.id != id) continue;
      if (s.refs == 0) {
        LogErrorf("surface %u released more times than it was held", id);
        return;
      }
      if (--s.refs == 0 && s.retired) {
        vaDestroySurfaces(dpy, &s.id, 1);
        surfaces.erase(surfaces.begin() + static_cast<long>(i));
      }
      return;
    }
    LogErrorf("release of surface %u, which is not in the pool", id);
  }

  // destroy the context and retire the pool
  void Unconfigure() {
    if (context != VA_INVALID_ID) vaDestroyContext(dpy, context);
    if (config != VA_INVALID_ID) vaDestroyConfig(dpy, config);
    context = VA_INVALID_ID;
    config = VA_INVALID_ID;
    std::vector<PoolSurface> kept;
    for (auto& s : surfaces) {
      if (s.refs == 0) {
        vaDestroySurfaces(dpy, &s.id, 1);
      } else {
        s.retired = true;
        kept.push_back(s);
      }
    }
    surfaces.swap(kept);
    configured = false;
  }
};

std::unique_ptr<DecodeSession> DecodeSession::Create(Codec codec, DecodeCallbacks callbacks, Status* status,
                                                     VaDevice& device) {
  DecoderCoreFactory factory = CoreFactoryFor(codec);
  if (!factory) {
    LogErrorf("no decoder core for codec %d is linked into this build", static_cast<int>(codec));
    if (status) *status = Status::kUnsupported;
    return nullptr;
  }
  return CreateWithCore(factory, std::move(callbacks), status, device);
}

std::unique_ptr<DecodeSession> DecodeSession::CreateWithCore(const DecoderCoreFactory& factory,
                                                             DecodeCallbacks callbacks, Status* status,
                                                             VaDevice& device) {
  Status st = Status::kOk;
  std::shared_ptr<Display> display = device.Open(&st);
  if (!display) {
    if (status) *status = st;
    return nullptr;
  }
  std::unique_ptr<DecodeSession> session(new DecodeSession());
  session->s_ = std::make_unique<State>();
  State& s = *session->s_;
  s.display = display;
  s.dpy = display->va();
  s.cb = std::move(callbacks);
  s.core = factory(session.get());
  if (!s.core) {
    if (status) *status = Status::kUnsupported;
    return nullptr;
  }
  if (status) *status = Status::kOk;
  return session;
}

DecodeSession::~DecodeSession() {
  if (!s_) return;
  s_->core.reset();
  {
    std::lock_guard<std::mutex> lock(s_->image_mutex);
    if (s_->image_valid) vaDestroyImage(s_->dpy, s_->image.image_id);
    s_->image_valid = false;
  }
  {
    std::lock_guard<std::mutex> lock(s_->rgba_mutex);
    if (s_->rgba_valid) vaDestroyImage(s_->dpy, s_->rgba.image_id);
    s_->rgba_valid = false;
  }
  std::lock_guard<std::mutex> lock(s_->mutex);
  s_->Unconfigure();
  for (auto& surf : s_->surfaces) vaDestroySurfaces(s_->dpy, &surf.id, 1);
  s_->surfaces.clear();
}

Status DecodeSession::Decode(const uint8_t* data, size_t size, uint64_t tag, bool codec_config) {
  return s_->core->Decode(data, size, tag, codec_config);
}

Status DecodeSession::Drain() { return s_->core->Drain(); }

void DecodeSession::Reset() { s_->core->Reset(); }

StreamInfo DecodeSession::stream_info() {
  std::lock_guard<std::mutex> lock(s_->mutex);
  return s_->info;
}

uint32_t DecodeSession::pool_size() {
  std::lock_guard<std::mutex> lock(s_->mutex);
  return static_cast<uint32_t>(s_->surfaces.size());
}

VADisplay DecodeSession::display() { return s_->dpy; }

Status DecodeSession::Configure(const StreamInfo& info, VAContextID* context) {
  State& s = *s_;
  if (info.rt_format != VA_RT_FORMAT_YUV420 && info.rt_format != VA_RT_FORMAT_YUV420_10) return Status::kUnsupported;
  if (info.coded_width == 0 || info.coded_height == 0 || info.min_surfaces == 0) return Status::kUnsupported;
  ComponentCaps caps;
  Codec codec;
  bool known = CodecForProfile(info.profile, &codec);
  bool limited = known && ComponentLimits(s.dpy, codec, Kind::kDecoder, &caps);
  if (limited && (info.coded_width < caps.min_width || info.coded_height < caps.min_height ||
                  info.coded_width > caps.max_width || info.coded_height > caps.max_height)) {
    LogErrorf("%s: coded size %ux%u is outside %ux%u..%ux%u%s, refused", caps.name.c_str(), info.coded_width,
              info.coded_height, caps.min_width, caps.min_height, caps.max_width, caps.max_height,
              caps.min_from_driver ? "" : " (the minimum is radeonsi's floor: the driver reports none)");
    return Status::kUnsupported;
  }
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    s.Unconfigure();
    VAConfigAttrib rt{VAConfigAttribRTFormat, info.rt_format};
    VAStatus st = vaCreateConfig(s.dpy, info.profile, VAEntrypointVLD, &rt, 1, &s.config);
    if (st != VA_STATUS_SUCCESS) {
      LogErrorf("decode config %s: %s", ProfileName(info.profile), vaErrorStr(st));
      s.config = VA_INVALID_ID;
      return st == VA_STATUS_ERROR_UNSUPPORTED_PROFILE || st == VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT
                 ? Status::kUnsupported
                 : Status::kVaError;
    }
    s.fourcc = info.rt_format == VA_RT_FORMAT_YUV420_10 ? VA_FOURCC_P010 : VA_FOURCC_NV12;
    uint32_t n = info.min_surfaces + kOutputSlack;
    std::vector<VASurfaceID> ids(n, VA_INVALID_SURFACE);
    VASurfaceAttrib fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = VASurfaceAttribPixelFormat;
    fmt.flags = VA_SURFACE_ATTRIB_SETTABLE;
    fmt.value.type = VAGenericValueTypeInteger;
    fmt.value.value.i = static_cast<int>(s.fourcc);
    auto align16 = [](uint32_t v) { return (v + 15) & ~15u; };
    uint32_t w = std::max(info.coded_width, align16(s.max_w)), h = std::max(info.coded_height, align16(s.max_h));
    if (limited) {
      w = std::max(info.coded_width, std::min(w, caps.max_width));
      h = std::max(info.coded_height, std::min(h, caps.max_height));
    }
    // radeonsi passes the context size as the picture size
    bool picture_context = known && (codec == Codec::kAvc || codec == Codec::kHevc);
    for (;;) {
      st = vaCreateSurfaces(s.dpy, info.rt_format, w, h, ids.data(), n, &fmt, 1);
      if (st == VA_STATUS_SUCCESS) {
        uint32_t cw = picture_context ? info.coded_width : w, ch = picture_context ? info.coded_height : h;
        st = vaCreateContext(s.dpy, s.config, static_cast<int>(cw), static_cast<int>(ch), VA_PROGRESSIVE, ids.data(),
                             static_cast<int>(n), &s.context);
        if (st == VA_STATUS_SUCCESS) break;
        LogErrorf("decode context %ux%u: %s", w, h, vaErrorStr(st));
        vaDestroySurfaces(s.dpy, ids.data(), static_cast<int>(n));
        s.context = VA_INVALID_ID;
      } else {
        LogErrorf("%u decode surfaces of %ux%u: %s", n, w, h, vaErrorStr(st));
      }
      if (w == info.coded_width && h == info.coded_height) {
        vaDestroyConfig(s.dpy, s.config);
        s.config = VA_INVALID_ID;
        if (st == VA_STATUS_ERROR_RESOLUTION_NOT_SUPPORTED) return Status::kUnsupported;
        return st == VA_STATUS_ERROR_ALLOCATION_FAILED ? Status::kNoMemory : Status::kVaError;
      }
      Logf("announced maximum %ux%u refused, falling back to the coded size %ux%u", w, h, info.coded_width,
           info.coded_height);
      w = info.coded_width;
      h = info.coded_height;
    }
    for (VASurfaceID id : ids) s.surfaces.push_back({id, 0, false});
    s.info = info;
    s.surf_w = w;
    s.surf_h = h;
    s.configured = true;
    *context = s.context;
    Logf("decoder configured: %s %ux%u (visible %ux%u+%u+%u), %u-bit, %u surfaces of %ux%u",
         ProfileName(info.profile), info.coded_width, info.coded_height, info.visible.width, info.visible.height,
         info.visible.left, info.visible.top, info.bit_depth, n, w, h);
  }
  if (s.cb.stream_changed) s.cb.stream_changed(info);
  return Status::kOk;
}

void DecodeSession::SurfaceSize(uint32_t* width, uint32_t* height) {
  std::lock_guard<std::mutex> lock(s_->mutex);
  *width = s_->surf_w;
  *height = s_->surf_h;
}

void DecodeSession::SetMaxPictureSize(uint32_t width, uint32_t height) {
  std::lock_guard<std::mutex> lock(s_->mutex);
  s_->max_w = width;
  s_->max_h = height;
}

Status DecodeSession::AcquireSurface(VASurfaceID* surface) {
  std::lock_guard<std::mutex> lock(s_->mutex);
  for (auto& surf : s_->surfaces) {
    if (!surf.retired && surf.refs == 0) {
      surf.refs = 1;
      *surface = surf.id;
      return Status::kOk;
    }
  }
  return Status::kNoMemory;
}

void DecodeSession::ReleaseSurface(VASurfaceID surface) {
  std::lock_guard<std::mutex> lock(s_->mutex);
  s_->Unref(surface);
}

void DecodeSession::Output(VASurfaceID surface, uint64_t tag, const Rect& crop, const ColorInfo& color) {
  State& s = *s_;
  VAStatus st = vaSyncSurface(s.dpy, surface);
  if (st != VA_STATUS_SUCCESS) LogErrorf("sync of decoded surface %u: %s", surface, vaErrorStr(st));
  Frame f{};
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    PoolSurface* p = s.Find(surface);
    if (!p) {
      LogErrorf("output of surface %u, which is not in the pool", surface);
      if (s.cb.skip) s.cb.skip(tag);
      return;
    }
    p->refs++;
    f.surface = surface;
    f.tag = tag;
    f.crop = crop;
    f.color = color;
    f.fourcc = s.fourcc;
    f.bit_depth = s.info.bit_depth;
    f.width = s.surf_w;
    f.height = s.surf_h;
  }
  if (s.cb.output) {
    s.cb.output(f);
  } else {
    ReleaseFrame(f);
  }
}

void DecodeSession::Skip(uint64_t tag) {
  if (s_->cb.skip) s_->cb.skip(tag);
}

void DecodeSession::ReleaseFrame(const Frame& frame) {
  std::lock_guard<std::mutex> lock(s_->mutex);
  s_->Unref(frame.surface);
}

Status DecodeSession::ToRgba(const Frame& frame, const DmabufImage& dst, const ColorInfo& color) {
  State& s = *s_;
  if (!IsRgbFourcc(dst.drm_fourcc)) return Status::kUnsupported;
  ImportedSurface out;
  Status st = out.Import(s.dpy, dst);
  if (st != Status::kOk) return st;
  return ToRgbaSurface(frame, out.id(), out.va_fourcc(), dst.width, dst.height, color);
}

Status DecodeSession::ToRgbaSurface(const Frame& frame, VASurfaceID surface, uint32_t va_fourcc, uint32_t width,
                                    uint32_t height, const ColorInfo& color) {
  State& s = *s_;
  Matrix m = MatrixFor(color.matrix, Matrix::kBt709);
  if (VppYuvToRgb(s.dpy, m, color.full_range, frame.fourcc == VA_FOURCC_P010)) {
    VARectangle src_rect{static_cast<int16_t>(frame.crop.left), static_cast<int16_t>(frame.crop.top),
                         static_cast<uint16_t>(frame.crop.width), static_cast<uint16_t>(frame.crop.height)};
    VARectangle dst_rect{0, 0, static_cast<uint16_t>(width), static_cast<uint16_t>(height)};
    return s.vpp.Run(s.dpy, frame.surface, src_rect, surface, dst_rect,
                     VppColor{VppMatrixCode(m), color.full_range, true, static_cast<uint8_t>(color.primaries),
                              static_cast<uint8_t>(color.transfer)});
  }
  std::lock_guard<std::mutex> lock(s.rgba_mutex);
  if (s.rgba_valid && (s.rgba.format.fourcc != va_fourcc || s.rgba.width != width || s.rgba.height != height)) {
    vaDestroyImage(s.dpy, s.rgba.image_id);
    s.rgba_valid = false;
  }
  if (!s.rgba_valid) {
    VAImageFormat fmt = RgbImageFormat(va_fourcc);
    if (vaCreateImage(s.dpy, &fmt, static_cast<int>(width), static_cast<int>(height), &s.rgba) != VA_STATUS_SUCCESS) {
      return Status::kNoMemory;
    }
    s.rgba_valid = true;
  }
  void* map = nullptr;
  if (vaMapBuffer(s.dpy, s.rgba.buf, &map) != VA_STATUS_SUCCESS || !map) return Status::kVaError;
  uint8_t* px = static_cast<uint8_t*>(map) + s.rgba.offsets[0];
  int32_t pitch = static_cast<int32_t>(s.rgba.pitches[0]);
  Status st = s.ReadFrame(frame, [&](const SemiPlanar& src) {
    SemiPlanarToRgba(src, m, color.full_range, px, pitch, static_cast<int32_t>(width), static_cast<int32_t>(height));
  });
  if (st == Status::kOk && (va_fourcc == VA_FOURCC_BGRA || va_fourcc == VA_FOURCC_BGRX)) {
    for (uint32_t r = 0; r < height; r++) {
      uint8_t* row = px + static_cast<int64_t>(r) * pitch;
      for (uint32_t x = 0; x < width; x++) std::swap(row[4 * x], row[4 * x + 2]);
    }
  }
  vaUnmapBuffer(s.dpy, s.rgba.buf);
  if (st != Status::kOk) return st;
  VAStatus vs = vaPutImage(s.dpy, surface, s.rgba.image_id, 0, 0, width, height, 0, 0, width, height);
  if (vs == VA_STATUS_SUCCESS) vs = vaSyncSurface(s.dpy, surface);
  if (vs != VA_STATUS_SUCCESS) {
    LogErrorf("RGBA upload into the output surface: %s", vaErrorStr(vs));
    return Status::kVaError;
  }
  return Status::kOk;
}

Status DecodeSession::State::ReadFrame(const Frame& frame, const std::function<void(const SemiPlanar&)>& use) {
  std::lock_guard<std::mutex> lock(image_mutex);
  if (image_valid && (image.format.fourcc != frame.fourcc || image.width < frame.width ||
                      image.height < frame.height)) {
    vaDestroyImage(dpy, image.image_id);
    image_valid = false;
  }
  if (!image_valid) {
    VAImageFormat fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.fourcc = frame.fourcc;
    fmt.byte_order = VA_LSB_FIRST;
    fmt.bits_per_pixel = frame.fourcc == VA_FOURCC_P010 ? 24 : 12;
    VAStatus st = vaCreateImage(dpy, &fmt, static_cast<int>(frame.width), static_cast<int>(frame.height), &image);
    if (st != VA_STATUS_SUCCESS) {
      LogErrorf("readback image %ux%u: %s", frame.width, frame.height, vaErrorStr(st));
      return Status::kNoMemory;
    }
    image_valid = true;
  }
  VAStatus st = vaGetImage(dpy, frame.surface, static_cast<int>(frame.crop.left), static_cast<int>(frame.crop.top),
                           frame.crop.width, frame.crop.height, image.image_id);
  if (st != VA_STATUS_SUCCESS) {
    LogErrorf("vaGetImage of surface %u: %s", frame.surface, vaErrorStr(st));
    return Status::kVaError;
  }
  void* map = nullptr;
  st = vaMapBuffer(dpy, image.buf, &map);
  if (st != VA_STATUS_SUCCESS || !map) {
    LogErrorf("map of the readback image: %s", vaErrorStr(st));
    return Status::kVaError;
  }
  uint8_t* base = static_cast<uint8_t*>(map);
  use(SemiPlanar{base + image.offsets[0], static_cast<int32_t>(image.pitches[0]), base + image.offsets[1],
                 static_cast<int32_t>(image.pitches[1]), static_cast<int32_t>(frame.crop.width),
                 static_cast<int32_t>(frame.crop.height), frame.fourcc == VA_FOURCC_P010 ? 2 : 1});
  vaUnmapBuffer(dpy, image.buf);
  return Status::kOk;
}

Status DecodeSession::ToYuv(const Frame& frame, const YuvDest& dst) {
  if (dst.bytes_per_sample != 1 && dst.bytes_per_sample != 2) return Status::kUnsupported;
  return s_->ReadFrame(frame, [&](const SemiPlanar& src) { CopySemiPlanarToDest(src, src.width, src.height, dst); });
}

}
