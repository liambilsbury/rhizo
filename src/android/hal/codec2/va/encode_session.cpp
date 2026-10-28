#include <string.h>

#include <algorithm>
#include <map>
#include <utility>
#include <vector>

#include "va/convert.h"
#include "va/log.h"
#include "va/runtime.h"
#include "va/vendor.h"
#include "va/vpp.h"

namespace rhizo::c2va {

std::unique_ptr<EncoderCore> CreateH264Encoder(EncoderHost* host, const EncoderConfig& config, Status* status)
    __attribute__((weak));
std::unique_ptr<EncoderCore> CreateHevcEncoder(EncoderHost* host, const EncoderConfig& config, Status* status)
    __attribute__((weak));

namespace {

EncoderCoreFactory CoreFactoryFor(Codec codec) {
  switch (codec) {
    case Codec::kAvc: return CreateH264Encoder ? EncoderCoreFactory(CreateH264Encoder) : nullptr;
    case Codec::kHevc: return CreateHevcEncoder ? EncoderCoreFactory(CreateHevcEncoder) : nullptr;
    default: return nullptr;
  }
}

// round v up to a multiple of a
uint32_t AlignUp(uint32_t v, uint32_t a) { return a <= 1 ? v : (v + a - 1) / a * a; }

struct PooledSurface {
  VASurfaceID id;
  bool busy;
};

}

struct EncodeSession::State {
  std::shared_ptr<Display> display;
  VADisplay dpy = nullptr;
  bool virgl = false;
  Codec codec;
  EncoderConfig config{};
  EncodeCallbacks cb;
  std::unique_ptr<EncoderCore> core;

  bool configured = false;
  bool failed = false;
  bool ten_bit = false;
  uint32_t rt_format = VA_RT_FORMAT_YUV420;
  uint32_t fourcc = VA_FOURCC_NV12;
  uint32_t surf_w = 0, surf_h = 0;
  VAConfigID va_config = VA_INVALID_ID;
  VAContextID context = VA_INVALID_ID;
  std::vector<PooledSurface> inputs;
  std::vector<PooledSurface> recons;
  std::map<uint64_t, VASurfaceID> in_flight;

  VAImage upload{};
  bool upload_valid = false;
  VAImage rgba_readback{};
  bool rgba_readback_valid = false;
  uint32_t rgba_readback_w = 0, rgba_readback_h = 0;

  Vpp vpp;
  RgbaPath rgba_path = RgbaPath::kUnknown;

  Status NewSurface(VASurfaceID* id) {
    VASurfaceAttrib fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = VASurfaceAttribPixelFormat;
    fmt.flags = VA_SURFACE_ATTRIB_SETTABLE;
    fmt.value.type = VAGenericValueTypeInteger;
    fmt.value.value.i = static_cast<int>(fourcc);
    VAStatus st = vaCreateSurfaces(dpy, rt_format, surf_w, surf_h, id, 1, &fmt, 1);
    if (st != VA_STATUS_SUCCESS) {
      LogErrorf("encoder surface %ux%u: %s", surf_w, surf_h, vaErrorStr(st));
      return Status::kNoMemory;
    }
    return Status::kOk;
  }

  // take a free surface from a pool of at most cap
  Status Take(std::vector<PooledSurface>* pool, uint32_t cap, VASurfaceID* id) {
    for (auto& p : *pool) {
      if (!p.busy) {
        p.busy = true;
        *id = p.id;
        return Status::kOk;
      }
    }
    if (pool->size() >= cap) return Status::kNoMemory;
    Status s = NewSurface(id);
    if (s != Status::kOk) return s;
    pool->push_back({*id, true});
    return Status::kOk;
  }

  static void Give(std::vector<PooledSurface>* pool, VASurfaceID id) {
    for (auto& p : *pool) {
      if (p.id == id) {
        p.busy = false;
        return;
      }
    }
  }

  void Unconfigure() {
    if (upload_valid) vaDestroyImage(dpy, upload.image_id);
    if (rgba_readback_valid) vaDestroyImage(dpy, rgba_readback.image_id);
    upload_valid = rgba_readback_valid = false;
    if (context != VA_INVALID_ID) vaDestroyContext(dpy, context);
    if (va_config != VA_INVALID_ID) vaDestroyConfig(dpy, va_config);
    context = VA_INVALID_ID;
    va_config = VA_INVALID_ID;
    for (auto& p : inputs) vaDestroySurfaces(dpy, &p.id, 1);
    for (auto& p : recons) vaDestroySurfaces(dpy, &p.id, 1);
    inputs.clear();
    recons.clear();
    in_flight.clear();
    configured = false;
  }

  // map the upload image for writing
  Status MapUpload(SemiPlanar* view) {
    if (!upload_valid) {
      VAImageFormat fmt;
      memset(&fmt, 0, sizeof(fmt));
      fmt.fourcc = fourcc;
      fmt.byte_order = VA_LSB_FIRST;
      fmt.bits_per_pixel = ten_bit ? 24 : 12;
      VAStatus st = vaCreateImage(dpy, &fmt, static_cast<int>(surf_w), static_cast<int>(surf_h), &upload);
      if (st != VA_STATUS_SUCCESS) {
        LogErrorf("upload image %ux%u: %s", surf_w, surf_h, vaErrorStr(st));
        return Status::kNoMemory;
      }
      upload_valid = true;
    }
    void* map = nullptr;
    VAStatus st = vaMapBuffer(dpy, upload.buf, &map);
    if (st != VA_STATUS_SUCCESS || !map) {
      LogErrorf("map of the upload image: %s", vaErrorStr(st));
      return Status::kVaError;
    }
    uint8_t* base = static_cast<uint8_t*>(map);
    *view = SemiPlanar{base + upload.offsets[0], static_cast<int32_t>(upload.pitches[0]), base + upload.offsets[1],
                       static_cast<int32_t>(upload.pitches[1]), static_cast<int32_t>(surf_w),
                       static_cast<int32_t>(surf_h), ten_bit ? 2 : 1};
    return Status::kOk;
  }

  Status PutUpload(VASurfaceID surface) {
    vaUnmapBuffer(dpy, upload.buf);
    VAStatus st = vaPutImage(dpy, surface, upload.image_id, 0, 0, surf_w, surf_h, 0, 0, surf_w, surf_h);
    if (st != VA_STATUS_SUCCESS) {
      LogErrorf("vaPutImage into encoder surface %u: %s", surface, vaErrorStr(st));
      return Status::kVaError;
    }
    return Status::kOk;
  }

  // return the config's matrix, BT.709 when unspecified
  Matrix RgbMatrix() const { return MatrixFor(config.color.matrix, Matrix::kBt709); }
};

std::unique_ptr<EncodeSession> EncodeSession::Create(Codec codec, const EncoderConfig& config,
                                                     EncodeCallbacks callbacks, Status* status, VaDevice& device) {
  EncoderCoreFactory factory = CoreFactoryFor(codec);
  if (!factory) {
    LogErrorf("no encoder core for codec %d is linked into this build", static_cast<int>(codec));
    if (status) *status = Status::kUnsupported;
    return nullptr;
  }
  return CreateWithCore(factory, codec, config, std::move(callbacks), status, device);
}

std::unique_ptr<EncodeSession> EncodeSession::CreateWithCore(const EncoderCoreFactory& factory, Codec codec,
                                                             const EncoderConfig& config,
                                                             EncodeCallbacks callbacks, Status* status,
                                                             VaDevice& device) {
  auto fail = [status](Status s) -> std::unique_ptr<EncodeSession> {
    if (status) *status = s;
    return nullptr;
  };
  Status st = Status::kOk;
  std::shared_ptr<Display> display = device.Open(&st);
  if (!display) return fail(st);

  ComponentCaps found;
  if (!ComponentLimits(display->va(), codec, Kind::kEncoder, &found)) return fail(Status::kUnsupported);
  const ComponentCaps* caps = &found;
  EncoderConfig cfg = config;
  if (std::find(caps->va_profiles.begin(), caps->va_profiles.end(), cfg.profile) == caps->va_profiles.end()) {
    LogErrorf("encoder profile %s is not offered", ProfileName(cfg.profile));
    return fail(Status::kUnsupported);
  }
  if (cfg.width < caps->min_width || cfg.height < caps->min_height || cfg.width > caps->max_width ||
      cfg.height > caps->max_height) {
    LogErrorf("encoder size %ux%u outside %ux%u..%ux%u", cfg.width, cfg.height, caps->min_width, caps->min_height,
              caps->max_width, caps->max_height);
    return fail(Status::kUnsupported);
  }
  if (cfg.min_coded_width == 0) cfg.min_coded_width = caps->coded_min_width;
  if (cfg.min_coded_height == 0) cfg.min_coded_height = caps->coded_min_height;
  auto rc_bit = [](EncoderConfig::RateControl rc) {
    switch (rc) {
      case EncoderConfig::RateControl::kCbr: return static_cast<uint32_t>(VA_RC_CBR);
      case EncoderConfig::RateControl::kVbr: return static_cast<uint32_t>(VA_RC_VBR);
      case EncoderConfig::RateControl::kCq: return static_cast<uint32_t>(VA_RC_CQP);
    }
    return 0u;
  };
  if (!(caps->va_rate_controls & rc_bit(cfg.rate_control))) {
    const EncoderConfig::RateControl order[] = {EncoderConfig::RateControl::kVbr, EncoderConfig::RateControl::kCbr,
                                                EncoderConfig::RateControl::kCq};
    for (auto rc : order) {
      if (caps->va_rate_controls & rc_bit(rc)) {
        cfg.rate_control = rc;
        break;
      }
    }
  }
  if (cfg.framerate_num == 0) cfg.framerate_num = 30;
  if (cfg.framerate_den == 0) cfg.framerate_den = 1;
  if (cfg.bitrate < 1000) cfg.bitrate = 1000;

  std::unique_ptr<EncodeSession> session(new EncodeSession());
  session->s_ = std::make_unique<State>();
  State& s = *session->s_;
  s.display = display;
  s.dpy = display->va();
  s.virgl = IsVirgl(s.dpy);
  s.codec = codec;
  s.config = cfg;
  s.cb = std::move(callbacks);
  s.ten_bit = cfg.profile == VAProfileHEVCMain10;
  s.rt_format = s.ten_bit ? VA_RT_FORMAT_YUV420_10 : VA_RT_FORMAT_YUV420;
  s.fourcc = s.ten_bit ? VA_FOURCC_P010 : VA_FOURCC_NV12;
  Status core_status = Status::kOk;
  s.core = factory(session.get(), s.config, &core_status);
  if (!s.core || core_status != Status::kOk) {
    return fail(core_status == Status::kOk ? Status::kUnsupported : core_status);
  }
  if (status) *status = Status::kOk;
  return session;
}

EncodeSession::~EncodeSession() {
  if (!s_) return;
  s_->core.reset();
  s_->Unconfigure();
}

const EncoderConfig& EncodeSession::config() const { return s_->config; }
RgbaPath EncodeSession::rgba_path() const { return s_->rgba_path; }
VADisplay EncodeSession::display() { return s_->dpy; }

Status EncodeSession::Configure(const EncoderConfig& config, VAConfigAttrib* attribs, int num_attribs,
                                uint32_t align_width, uint32_t align_height, VAContextID* context) {
  State& s = *s_;
  if (!s.in_flight.empty()) {
    LogErrorf("encoder reconfigured with %zu pictures in flight", s.in_flight.size());
    return Status::kUnsupported;
  }
  ComponentCaps caps;
  if (ComponentLimits(s.dpy, s.codec, Kind::kEncoder, &caps) &&
      (config.width < caps.min_width || config.height < caps.min_height || config.width > caps.max_width ||
       config.height > caps.max_height)) {
    LogErrorf("%s: size %ux%u is outside %ux%u..%ux%u, refused", caps.name.c_str(), config.width, config.height,
              caps.min_width, caps.min_height, caps.max_width, caps.max_height);
    return Status::kUnsupported;
  }
  s.Unconfigure();
  std::vector<VAConfigAttrib> attrs(attribs, attribs + std::max(num_attribs, 0));
  bool has_rt = false;
  for (const auto& a : attrs) has_rt |= a.type == VAConfigAttribRTFormat;
  if (!has_rt) attrs.push_back({VAConfigAttribRTFormat, s.rt_format});
  VAStatus st = vaCreateConfig(s.dpy, config.profile, VAEntrypointEncSlice, attrs.data(),
                               static_cast<int>(attrs.size()), &s.va_config);
  if (st != VA_STATUS_SUCCESS) {
    LogErrorf("encode config %s: %s", ProfileName(config.profile), vaErrorStr(st));
    s.va_config = VA_INVALID_ID;
    return Status::kVaError;
  }
  uint32_t drv_w = s.codec == Codec::kHevc ? 64 : 16, drv_h = 16;
  unsigned int na = 0;
  if (vaQuerySurfaceAttributes(s.dpy, s.va_config, nullptr, &na) == VA_STATUS_SUCCESS && na > 0) {
    std::vector<VASurfaceAttrib> sa(na);
    if (vaQuerySurfaceAttributes(s.dpy, s.va_config, sa.data(), &na) == VA_STATUS_SUCCESS) {
      for (unsigned int i = 0; i < na; i++) {
        if (sa[i].type != VASurfaceAttribAlignmentSize || sa[i].value.type != VAGenericValueTypeInteger) continue;
        uint32_t v = static_cast<uint32_t>(sa[i].value.value.i);
        drv_w = 1u << (v & 0xf);
        drv_h = 1u << ((v >> 4) & 0xf);
      }
    }
  }
  s.surf_w = AlignUp(AlignUp(config.width, align_width), drv_w);
  s.surf_h = AlignUp(AlignUp(config.height, align_height), drv_h);
  if (s.surf_w < caps.coded_min_width || s.surf_h < caps.coded_min_height) {
    LogErrorf("%s: coded %ux%u is below the driver's %ux%u, refused", caps.name.c_str(), s.surf_w, s.surf_h,
              caps.coded_min_width, caps.coded_min_height);
    vaDestroyConfig(s.dpy, s.va_config);
    s.va_config = VA_INVALID_ID;
    return Status::kUnsupported;
  }
  st = vaCreateContext(s.dpy, s.va_config, static_cast<int>(s.surf_w), static_cast<int>(s.surf_h), VA_PROGRESSIVE,
                       nullptr, 0, &s.context);
  if (st != VA_STATUS_SUCCESS) {
    LogErrorf("encode context %ux%u: %s", s.surf_w, s.surf_h, vaErrorStr(st));
    vaDestroyConfig(s.dpy, s.va_config);
    s.va_config = VA_INVALID_ID;
    s.context = VA_INVALID_ID;
    return Status::kVaError;
  }
  s.configured = true;
  *context = s.context;
  Logf("encoder configured: %s %ux%u in %ux%u surfaces, %u bit/s", ProfileName(config.profile), config.width,
       config.height, s.surf_w, s.surf_h, config.bitrate);
  return Status::kOk;
}

Status EncodeSession::AcquireReconSurface(VASurfaceID* surface) {
  if (!s_->configured) return Status::kVaError;
  return s_->Take(&s_->recons, kMaxReconSurfaces, surface);
}

void EncodeSession::ReleaseReconSurface(VASurfaceID surface) { State::Give(&s_->recons, surface); }

void EncodeSession::Output(const uint8_t* data, size_t size, uint64_t tag, int64_t pts, bool keyframe,
                           bool codec_config) {
  State& s = *s_;
  if (s.cb.output) s.cb.output(data, size, tag, pts, keyframe, codec_config);
  if (codec_config) return;
  auto it = s.in_flight.find(tag);
  if (it != s.in_flight.end()) {
    State::Give(&s.inputs, it->second);
    s.in_flight.erase(it);
  }
}

namespace {

Status Submit(EncodeSession::State& s, EncoderCore* core, VASurfaceID surface, uint64_t tag, int64_t pts,
              bool keyframe);

// stretch src's edge pixels over dst's padding beyond w x h
Status FillPadding(EncodeSession::State& s, VASurfaceID src, VASurfaceID dst, uint32_t w, uint32_t h,
                   const VppColor& color) {
  if (w == 0 || h == 0) return Status::kOk;
  auto run = [&](uint32_t sx, uint32_t sy, uint32_t sw, uint32_t sh, uint32_t dx, uint32_t dy, uint32_t dw,
                 uint32_t dh) {
    VARectangle sr{static_cast<int16_t>(sx), static_cast<int16_t>(sy), static_cast<uint16_t>(sw),
                   static_cast<uint16_t>(sh)};
    VARectangle dr{static_cast<int16_t>(dx), static_cast<int16_t>(dy), static_cast<uint16_t>(dw),
                   static_cast<uint16_t>(dh)};
    return s.vpp.Run(s.dpy, src, sr, dst, dr, color);
  };
  uint32_t pw = s.surf_w > w ? s.surf_w - w : 0, ph = s.surf_h > h ? s.surf_h - h : 0;
  Status st = Status::kOk;
  if (pw) st = run(w - 1, 0, 1, h, w, 0, pw, h);
  if (st == Status::kOk && ph) st = run(0, h - 1, w, 1, 0, h, w, ph);
  if (st == Status::kOk && pw && ph) st = run(w - 1, h - 1, 1, 1, w, h, pw, ph);
  return st;
}

}

Status EncodeSession::Encode(const YuvSrc& src, uint64_t tag, int64_t pts, bool keyframe) {
  State& s = *s_;
  if (s.failed) return Status::kVaError;
  if (!s.configured) {
    LogErrorf("encode before the core configured the session");
    return Status::kVaError;
  }
  VASurfaceID surface;
  Status st = s.Take(&s.inputs, kMaxInputSurfaces, &surface);
  if (st != Status::kOk) return st;
  SemiPlanar view;
  st = s.MapUpload(&view);
  if (st == Status::kOk) {
    CopySrcToSemiPlanar(src, view);
    st = s.PutUpload(surface);
  }
  if (st != Status::kOk) {
    State::Give(&s.inputs, surface);
    return st;
  }
  return Submit(s, s.core.get(), surface, tag, pts, keyframe);
}

Status EncodeSession::Encode(const RgbaSrc& src, uint64_t tag, int64_t pts, bool keyframe) {
  State& s = *s_;
  if (s.failed) return Status::kVaError;
  if (!s.configured) {
    LogErrorf("encode before the core configured the session");
    return Status::kVaError;
  }
  VASurfaceID surface;
  Status st = s.Take(&s.inputs, kMaxInputSurfaces, &surface);
  if (st != Status::kOk) return st;
  SemiPlanar view;
  st = s.MapUpload(&view);
  if (st == Status::kOk) {
    RgbaToSemiPlanar(src.data, src.row_stride, src.width, src.height, s.RgbMatrix(), s.config.color.full_range,
                     view);
    st = s.PutUpload(surface);
  }
  if (st != Status::kOk) {
    State::Give(&s.inputs, surface);
    return st;
  }
  return Submit(s, s.core.get(), surface, tag, pts, keyframe);
}

// return whether a YUV dmabuf imports safely
bool EncodeSession::ImportsYuvDmabuf(VADisplay display) { return !IsVirgl(display); }

Status EncodeSession::Encode(const DmabufImage& src, uint64_t tag, int64_t pts, bool keyframe) {
  State& s = *s_;
  if (s.failed) return Status::kVaError;
  if (!s.configured) {
    LogErrorf("encode before the core configured the session");
    return Status::kVaError;
  }
  bool rgb = IsRgbFourcc(src.drm_fourcc);
  if (!rgb && s.virgl) return Status::kUnsupported;
  // a SurfaceFlinger virtual display has alpha 0 where nothing is shown
  ImportedSurface in;
  Status st = in.Import(s.dpy, src, /*opaque=*/rgb);
  if (st != Status::kOk) {
    if (rgb) s.rgba_path = RgbaPath::kUnsupported;
    return Status::kUnsupported;
  }
  VASurfaceID surface;
  st = s.Take(&s.inputs, kMaxInputSurfaces, &surface);
  if (st != Status::kOk) return st;
  uint32_t w = std::min(src.width, s.config.width), h = std::min(src.height, s.config.height);
  VARectangle src_rect{0, 0, static_cast<uint16_t>(w), static_cast<uint16_t>(h)};
  VARectangle dst_rect{0, 0, static_cast<uint16_t>(w), static_cast<uint16_t>(h)};
  bool vpp_ok = rgb ? VppRgbToYuv(s.dpy, s.RgbMatrix(), s.config.color.full_range) : VppUsable(s.dpy);
  if (rgb && s.rgba_path == RgbaPath::kCpu) vpp_ok = false;
  if (!rgb && !vpp_ok) {
    State::Give(&s.inputs, surface);
    return Status::kUnsupported;
  }
  if (vpp_ok) {
    const ColorInfo& ci = s.config.color;
    VppColor color = rgb ? VppColor{VppMatrixCode(s.RgbMatrix()), true, ci.full_range,
                                    static_cast<uint8_t>(ci.primaries), static_cast<uint8_t>(ci.transfer)}
                         : VppColor{0, false, false};
    st = s.vpp.Run(s.dpy, in.id(), src_rect, surface, dst_rect, color);
    if (st == Status::kOk) st = FillPadding(s, in.id(), surface, w, h, color);
    if (st == Status::kOk) {
      if (rgb && s.rgba_path == RgbaPath::kUnknown) {
        s.rgba_path = RgbaPath::kVpp;
        Logf("RGBA encoder input: VPP from the imported dmabuf");
      }
      return Submit(s, s.core.get(), surface, tag, pts, keyframe);
    }
    if (!rgb) {
      State::Give(&s.inputs, surface);
      return Status::kUnsupported;
    }
  }
  if (s.rgba_path != RgbaPath::kCpu) {
    s.rgba_path = RgbaPath::kCpu;
    Logf("RGBA encoder input: vaGetImage and CPU conversion");
  }
  if (s.rgba_readback_valid && (s.rgba_readback_w != src.width || s.rgba_readback_h != src.height ||
                                s.rgba_readback.format.fourcc != in.va_fourcc())) {
    vaDestroyImage(s.dpy, s.rgba_readback.image_id);
    s.rgba_readback_valid = false;
  }
  if (!s.rgba_readback_valid) {
    VAImageFormat fmt = RgbImageFormat(in.va_fourcc());
    if (vaCreateImage(s.dpy, &fmt, static_cast<int>(src.width), static_cast<int>(src.height), &s.rgba_readback) !=
        VA_STATUS_SUCCESS) {
      State::Give(&s.inputs, surface);
      return Status::kNoMemory;
    }
    s.rgba_readback_valid = true;
    s.rgba_readback_w = src.width;
    s.rgba_readback_h = src.height;
  }
  VAStatus vs = vaGetImage(s.dpy, in.id(), 0, 0, src.width, src.height, s.rgba_readback.image_id);
  void* map = nullptr;
  if (vs == VA_STATUS_SUCCESS) vs = vaMapBuffer(s.dpy, s.rgba_readback.buf, &map);
  if (vs != VA_STATUS_SUCCESS || !map) {
    LogErrorf("readback of the imported RGBA: %s", vaErrorStr(vs));
    State::Give(&s.inputs, surface);
    s.rgba_path = RgbaPath::kUnsupported;
    return Status::kUnsupported;
  }
  if (in.va_fourcc() == VA_FOURCC_BGRA || in.va_fourcc() == VA_FOURCC_BGRX) {
    uint8_t* p = static_cast<uint8_t*>(map) + s.rgba_readback.offsets[0];
    for (uint32_t r = 0; r < src.height; r++) {
      uint8_t* row = p + static_cast<size_t>(r) * s.rgba_readback.pitches[0];
      for (uint32_t x = 0; x < src.width; x++) std::swap(row[4 * x], row[4 * x + 2]);
    }
  }
  SemiPlanar view;
  st = s.MapUpload(&view);
  if (st == Status::kOk) {
    const uint8_t* px = static_cast<const uint8_t*>(map) + s.rgba_readback.offsets[0];
    RgbaToSemiPlanar(px, static_cast<int32_t>(s.rgba_readback.pitches[0]), static_cast<int32_t>(w),
                     static_cast<int32_t>(h), s.RgbMatrix(), s.config.color.full_range, view);
    st = s.PutUpload(surface);
  }
  vaUnmapBuffer(s.dpy, s.rgba_readback.buf);
  if (st != Status::kOk) {
    State::Give(&s.inputs, surface);
    return st;
  }
  return Submit(s, s.core.get(), surface, tag, pts, keyframe);
}

namespace {

// submit an input surface to the core
Status Submit(EncodeSession::State& s, EncoderCore* core, VASurfaceID surface, uint64_t tag, int64_t pts,
              bool keyframe) {
  s.in_flight[tag] = surface;
  Status st = core->Encode(surface, tag, pts, keyframe);
  if (st != Status::kOk) {
    s.failed = true;
    LogErrorf("the encoder core failed (status %d): the session takes no more pictures", static_cast<int>(st));
    auto it = s.in_flight.find(tag);
    if (it != s.in_flight.end() && it->second == surface) {
      EncodeSession::State::Give(&s.inputs, surface);
      s.in_flight.erase(it);
    }
  }
  return st;
}

}

Status EncodeSession::Drain() {
  State& s = *s_;
  Status st = s.core->Drain();
  for (auto& kv : s.in_flight) State::Give(&s.inputs, kv.second);
  s.in_flight.clear();
  return st;
}

Status EncodeSession::SetBitrate(uint32_t bitrate) {
  s_->config.bitrate = bitrate;
  return s_->core->SetBitrate(bitrate);
}

}
