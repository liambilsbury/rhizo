#include "va/vpp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <map>
#include <string>

#include <va/va_drmcommon.h>
#include <va/va_vpp.h>

#include "va/convert.h"
#include "va/log.h"

namespace rhizo::c2va {

namespace {

bool VaFormatFor(uint32_t drm, uint32_t* va_fourcc, uint32_t* rt_format) {
  switch (drm) {
    case kDrmAbgr8888: *va_fourcc = VA_FOURCC_RGBA; *rt_format = VA_RT_FORMAT_RGB32; return true;
    case kDrmXbgr8888: *va_fourcc = VA_FOURCC_RGBX; *rt_format = VA_RT_FORMAT_RGB32; return true;
    case kDrmArgb8888: *va_fourcc = VA_FOURCC_BGRA; *rt_format = VA_RT_FORMAT_RGB32; return true;
    case kDrmXrgb8888: *va_fourcc = VA_FOURCC_BGRX; *rt_format = VA_RT_FORMAT_RGB32; return true;
    case kDrmNv12: *va_fourcc = VA_FOURCC_NV12; *rt_format = VA_RT_FORMAT_YUV420; return true;
    case kDrmYvu420: *va_fourcc = VA_FOURCC_YV12; *rt_format = VA_RT_FORMAT_YUV420; return true;
    case kDrmYuv420: *va_fourcc = VA_FOURCC_I420; *rt_format = VA_RT_FORMAT_YUV420; return true;
    case kDrmP010: *va_fourcc = VA_FOURCC_P010; *rt_format = VA_RT_FORMAT_YUV420_10; return true;
    default: return false;
  }
}

}

bool IsRgbFourcc(uint32_t drm) {
  return drm == kDrmAbgr8888 || drm == kDrmXbgr8888 || drm == kDrmArgb8888 || drm == kDrmXrgb8888;
}

uint32_t OpaqueDrmFormat(uint32_t drm) {
  if (drm == kDrmAbgr8888) return kDrmXbgr8888;
  if (drm == kDrmArgb8888) return kDrmXrgb8888;
  return drm;
}

uint8_t VppMatrixCode(Matrix m) {
  switch (m) {
    case Matrix::kBt601: return 6;
    case Matrix::kBt709: return 1;
    case Matrix::kBt2020: return 9;
    case Matrix::kFcc: return 4;
    case Matrix::kSmpte240m: return 7;
  }
  return 1;
}

void FillVppColor(const VppColor& color, VAProcPipelineParameterBuffer* p) {
  VAProcColorStandardType standard = color.matrix ? VAProcColorStandardExplicit : VAProcColorStandardNone;
  p->surface_color_standard = standard;
  p->output_color_standard = standard;
  VAProcColorProperties* sides[2] = {&p->input_color_properties, &p->output_color_properties};
  for (int i = 0; i < 2; i++) {
    bool full = i == 0 ? color.src_full_range : color.dst_full_range;
    sides[i]->color_range = full ? VA_SOURCE_RANGE_FULL : VA_SOURCE_RANGE_REDUCED;
    sides[i]->matrix_coefficients = color.matrix;
    sides[i]->colour_primaries = color.primaries;
    sides[i]->transfer_characteristics = color.transfer;
  }
}

ImportedSurface::~ImportedSurface() {
  if (id_ != VA_INVALID_SURFACE) vaDestroySurfaces(dpy_, &id_, 1);
}

Status ImportedSurface::Import(VADisplay dpy, const DmabufImage& img, bool opaque) {
  uint32_t va_fourcc = 0, rt = 0;
  uint32_t drm = opaque ? OpaqueDrmFormat(img.drm_fourcc) : img.drm_fourcc;
  if (!VaFormatFor(drm, &va_fourcc, &rt)) {
    LogErrorf("import: DRM format 0x%08x is not one the runtime maps", img.drm_fourcc);
    return Status::kUnsupported;
  }
  if (img.fd < 0 || img.num_planes < 1 || img.num_planes > 4 || img.width == 0 || img.height == 0 ||
      img.num_objects < 0 || img.num_objects > 4) {
    return Status::kUnsupported;
  }
  int num_objects = img.num_objects > 0 ? img.num_objects : 1;
  for (int i = 0; i < img.num_planes; i++) {
    if (img.num_objects > 0 && img.plane_object[i] >= static_cast<uint32_t>(num_objects)) return Status::kUnsupported;
  }
  VADRMPRIMESurfaceDescriptor desc;
  memset(&desc, 0, sizeof(desc));
  desc.fourcc = va_fourcc;
  desc.width = img.width;
  desc.height = img.height;
  desc.num_objects = static_cast<uint32_t>(num_objects);
  for (int o = 0; o < num_objects; o++) {
    int fd = img.num_objects > 0 ? img.object_fds[o] : img.fd;
    if (fd < 0) return Status::kUnsupported;
    off_t size = lseek(fd, 0, SEEK_END);
    lseek(fd, 0, SEEK_SET);
    desc.objects[o].fd = fd;
    desc.objects[o].size = size > 0 ? static_cast<uint32_t>(size) : 0;
    desc.objects[o].drm_format_modifier = img.modifier;
  }
  desc.num_layers = 1;
  desc.layers[0].drm_format = drm;
  desc.layers[0].num_planes = static_cast<uint32_t>(img.num_planes);
  for (int i = 0; i < img.num_planes; i++) {
    desc.layers[0].object_index[i] = img.num_objects > 0 ? img.plane_object[i] : 0;
    desc.layers[0].offset[i] = img.offsets[i];
    desc.layers[0].pitch[i] = img.pitches[i];
  }
  VASurfaceAttrib attrs[2];
  memset(attrs, 0, sizeof(attrs));
  attrs[0].type = VASurfaceAttribMemoryType;
  attrs[0].flags = VA_SURFACE_ATTRIB_SETTABLE;
  attrs[0].value.type = VAGenericValueTypeInteger;
  attrs[0].value.value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2;
  attrs[1].type = VASurfaceAttribExternalBufferDescriptor;
  attrs[1].flags = VA_SURFACE_ATTRIB_SETTABLE;
  attrs[1].value.type = VAGenericValueTypePointer;
  attrs[1].value.value.p = &desc;
  VASurfaceID id = VA_INVALID_SURFACE;
  VAStatus st = vaCreateSurfaces(dpy, rt, img.width, img.height, &id, 1, attrs, 2);
  if (st != VA_STATUS_SUCCESS) {
    LogErrorf("import of a %ux%u dmabuf (DRM 0x%08x, modifier 0x%llx, %d planes) refused: %s", img.width,
              img.height, img.drm_fourcc, static_cast<unsigned long long>(img.modifier), img.num_planes,
              vaErrorStr(st));
    return Status::kVaError;
  }
  if (id_ != VA_INVALID_SURFACE) vaDestroySurfaces(dpy_, &id_, 1);
  dpy_ = dpy;
  id_ = id;
  va_fourcc_ = va_fourcc;
  return Status::kOk;
}

bool VppDraws(VADisplay display) { return VppUsable(display); }

VAImageFormat RgbImageFormat(uint32_t va_fourcc) {
  VAImageFormat f;
  memset(&f, 0, sizeof(f));
  f.fourcc = va_fourcc;
  f.byte_order = VA_LSB_FIRST;
  f.bits_per_pixel = 32;
  bool alpha = va_fourcc == VA_FOURCC_RGBA || va_fourcc == VA_FOURCC_BGRA;
  f.depth = alpha ? 32 : 24;
  bool rgb_order = va_fourcc == VA_FOURCC_RGBA || va_fourcc == VA_FOURCC_RGBX;
  f.red_mask = rgb_order ? 0x000000ff : 0x00ff0000;
  f.green_mask = 0x0000ff00;
  f.blue_mask = rgb_order ? 0x00ff0000 : 0x000000ff;
  f.alpha_mask = alpha ? 0xff000000 : 0;
  return f;
}

namespace {

// a VPP conversion case
struct Case {
  bool yuv_to_rgb;
  Matrix matrix;
  bool full_range;
  bool ten_bit;
  int Key() const {
    return (yuv_to_rgb ? 1 : 0) | (static_cast<int>(matrix) << 1) | ((full_range ? 1 : 0) << 4) |
           ((ten_bit ? 1 : 0) << 5);
  }
  std::string Name() const {
    static const char* names[] = {"BT.601", "BT.709", "BT.2020", "FCC", "SMPTE 240M"};
    const char* way = yuv_to_rgb ? (ten_bit ? "P010 -> RGBA " : "NV12 -> RGBA ") : "RGBX (alpha 0/128/255) -> NV12 ";
    return std::string(way) +
           names[static_cast<int>(matrix)] + (full_range ? " full" : " limited");
  }
};

VASurfaceID MakeSurface(VADisplay dpy, uint32_t fourcc, uint32_t rt, uint32_t w, uint32_t h) {
  VASurfaceAttrib attr;
  memset(&attr, 0, sizeof(attr));
  attr.type = VASurfaceAttribPixelFormat;
  attr.flags = VA_SURFACE_ATTRIB_SETTABLE;
  attr.value.type = VAGenericValueTypeInteger;
  attr.value.value.i = static_cast<int>(fourcc);
  VASurfaceID s = VA_INVALID_SURFACE;
  if (vaCreateSurfaces(dpy, rt, w, h, &s, 1, &attr, 1) != VA_STATUS_SUCCESS) return VA_INVALID_SURFACE;
  return s;
}

VAImageFormat SemiPlanarFormat(bool ten_bit) {
  VAImageFormat f;
  memset(&f, 0, sizeof(f));
  f.fourcc = ten_bit ? VA_FOURCC_P010 : VA_FOURCC_NV12;
  f.byte_order = VA_LSB_FIRST;
  f.bits_per_pixel = ten_bit ? 24 : 12;
  return f;
}

// check a VPP conversion against the CPU on test strips
bool Prove(VADisplay dpy, const Case& c, std::string* why) {
  const uint32_t w = 64, h = 64;
  const bool yuv_src = c.yuv_to_rgb;
  const int bps = c.ten_bit ? 2 : 1;
  VASurfaceID src = yuv_src ? MakeSurface(dpy, c.ten_bit ? VA_FOURCC_P010 : VA_FOURCC_NV12,
                                          c.ten_bit ? VA_RT_FORMAT_YUV420_10 : VA_RT_FORMAT_YUV420, w, h)
                            : MakeSurface(dpy, VA_FOURCC_RGBX, VA_RT_FORMAT_RGB32, w, h);
  VASurfaceID dst = yuv_src ? MakeSurface(dpy, VA_FOURCC_RGBA, VA_RT_FORMAT_RGB32, w, h)
                            : MakeSurface(dpy, VA_FOURCC_NV12, VA_RT_FORMAT_YUV420, w, h);
  VAImageFormat in_fmt = yuv_src ? SemiPlanarFormat(c.ten_bit) : RgbImageFormat(VA_FOURCC_RGBX);
  VAImageFormat out_fmt = yuv_src ? RgbImageFormat(VA_FOURCC_RGBA) : SemiPlanarFormat(false);
  VAImage in{}, out{};
  bool have_in = false, have_out = false, ok = false;
  const uint8_t yuv[2][3] = {{16, 16, 16}, {235, 128, 128}};
  const uint8_t rgb[4][4] = {{0, 0, 0, 0}, {0, 255, 0, 0}, {200, 200, 200, 128}, {255, 0, 0, 255}};
  const int strips = yuv_src ? 2 : 4;
  const uint32_t strip_w = w / strips;
  do {
    if (src == VA_INVALID_SURFACE || dst == VA_INVALID_SURFACE) {
      *why = "surfaces refused";
      break;
    }
    if (vaCreateImage(dpy, &in_fmt, w, h, &in) != VA_STATUS_SUCCESS) break;
    have_in = true;
    void* map = nullptr;
    if (!yuv_src) {
      if (vaCreateImage(dpy, &out_fmt, w, h, &out) != VA_STATUS_SUCCESS) break;
      have_out = true;
      if (vaMapBuffer(dpy, out.buf, &map) != VA_STATUS_SUCCESS || !map) break;
      uint8_t* q = static_cast<uint8_t*>(map);
      for (uint32_t r = 0; r < h; r++) memset(q + out.offsets[0] + r * out.pitches[0], 77, w);
      for (uint32_t r = 0; r < h / 2; r++) memset(q + out.offsets[1] + r * out.pitches[1], 200, w);
      vaUnmapBuffer(dpy, out.buf);
      if (vaPutImage(dpy, dst, out.image_id, 0, 0, w, h, 0, 0, w, h) != VA_STATUS_SUCCESS) {
        *why = "vaPutImage of the destination refused";
        break;
      }
    }
    if (vaMapBuffer(dpy, in.buf, &map) != VA_STATUS_SUCCESS || !map) break;
    uint8_t* p = static_cast<uint8_t*>(map);
    auto put = [&](uint8_t* at, uint8_t v) {
      if (bps == 1) {
        *at = v;
      } else {
        at[0] = 0;
        at[1] = v;
      }
    };
    for (uint32_t r = 0; r < h; r++) {
      for (uint32_t x = 0; x < w; x++) {
        int k = static_cast<int>(x / strip_w);
        if (yuv_src) {
          put(p + in.offsets[0] + r * in.pitches[0] + x * bps, yuv[k][0]);
          if (r % 2 == 0 && x % 2 == 0) {
            uint8_t* cr = p + in.offsets[1] + (r / 2) * in.pitches[1] + (x / 2) * 2 * bps;
            put(cr, yuv[k][1]);
            put(cr + bps, yuv[k][2]);
          }
        } else {
          memcpy(p + in.offsets[0] + r * in.pitches[0] + 4 * x, rgb[k], 4);
        }
      }
    }
    vaUnmapBuffer(dpy, in.buf);
    if (vaPutImage(dpy, src, in.image_id, 0, 0, w, h, 0, 0, w, h) != VA_STATUS_SUCCESS) {
      *why = "vaPutImage refused";
      break;
    }
    Vpp vpp;
    VARectangle rect{0, 0, static_cast<uint16_t>(w), static_cast<uint16_t>(h)};
    VppColor color{VppMatrixCode(c.matrix), yuv_src ? c.full_range : true, yuv_src ? true : c.full_range};
    if (vpp.Run(dpy, src, rect, dst, rect, color) != Status::kOk) {
      *why = "VPP refused";
      break;
    }
    if (!have_out) {
      if (vaCreateImage(dpy, &out_fmt, w, h, &out) != VA_STATUS_SUCCESS) break;
      have_out = true;
    }
    if (vaGetImage(dpy, dst, 0, 0, w, h, out.image_id) != VA_STATUS_SUCCESS) {
      *why = "vaGetImage refused";
      break;
    }
    if (vaMapBuffer(dpy, out.buf, &map) != VA_STATUS_SUCCESS || !map) break;
    const uint8_t* o = static_cast<const uint8_t*>(map);
    ok = true;
    char line[200];
    for (int k = 0; k < strips; k++) {
      uint32_t x = k * strip_w + strip_w / 2;
      int got[3], want[3], tol;
      if (yuv_src) {
        const uint8_t* px = o + out.offsets[0] + (h / 2) * out.pitches[0] + 4 * x;
        uint8_t ys[2] = {yuv[k][0], yuv[k][0]}, uv[2] = {yuv[k][1], yuv[k][2]}, ref[4];
        SemiPlanar one{ys, 2, uv, 2, 1, 1, 1};
        SemiPlanarToRgba(one, c.matrix, c.full_range, ref, 4, 1, 1);
        for (int i = 0; i < 3; i++) {
          got[i] = px[i];
          want[i] = ref[i];
        }
        if (px[3] != 255) ok = false;
        tol = 2;
      } else {
        const uint8_t* yrow = o + out.offsets[0] + (h / 2) * out.pitches[0];
        const uint8_t* crow = o + out.offsets[1] + (h / 4) * out.pitches[1];
        uint8_t block[16], ry[4], ruv[2];
        for (int i = 0; i < 4; i++) memcpy(block + 4 * i, rgb[k], 4);
        SemiPlanar ref{ry, 2, ruv, 2, 2, 2, 1};
        RgbaToSemiPlanar(block, 8, 2, 2, c.matrix, c.full_range, ref);
        got[0] = yrow[x];
        got[1] = crow[(x / 2) * 2];
        got[2] = crow[(x / 2) * 2 + 1];
        want[0] = ry[0];
        want[1] = ruv[0];
        want[2] = ruv[1];
        tol = 1;
      }
      for (int i = 0; i < 3; i++) ok = ok && abs(got[i] - want[i]) <= tol;
      snprintf(line, sizeof(line), "%s(%d,%d,%d) want (%d,%d,%d)", k ? " " : "", got[0], got[1], got[2], want[0],
               want[1], want[2]);
      *why += line;
    }
    vaUnmapBuffer(dpy, out.buf);
  } while (false);
  if (have_in) vaDestroyImage(dpy, in.image_id);
  if (have_out) vaDestroyImage(dpy, out.image_id);
  if (src != VA_INVALID_SURFACE) vaDestroySurfaces(dpy, &src, 1);
  if (dst != VA_INVALID_SURFACE) vaDestroySurfaces(dpy, &dst, 1);
  return ok;
}

// return a case's cached verdict
bool Proved(VADisplay dpy, const Case& c) {
  static std::mutex mutex;
  static std::map<int, bool>* verdicts = new std::map<int, bool>();
  std::lock_guard<std::mutex> lock(mutex);
  auto it = verdicts->find(c.Key());
  if (it != verdicts->end()) return it->second;
  std::string why;
  bool ok = Prove(dpy, c, &why);
  (*verdicts)[c.Key()] = ok;
  if (ok) {
    Logf("VPP self-check: %s: %s ok", c.Name().c_str(), why.c_str());
  } else {
    LogErrorf("VPP self-check: %s: %s WRONG; this conversion goes through the CPU in this process", c.Name().c_str(),
              why.empty() ? "nothing readable" : why.c_str());
  }
  return ok;
}

}

bool VppUsable(VADisplay dpy) { return Proved(dpy, Case{true, Matrix::kBt709, false, false}); }

bool VppYuvToRgb(VADisplay dpy, Matrix m, bool full_range, bool ten_bit) {
  return VppUsable(dpy) && Proved(dpy, Case{true, m, full_range, ten_bit});
}

bool VppRgbToYuv(VADisplay dpy, Matrix m, bool full_range) {
  return VppUsable(dpy) && Proved(dpy, Case{false, m, full_range, false});
}

Vpp::~Vpp() {
  if (context_ != VA_INVALID_ID) vaDestroyContext(dpy_, context_);
  if (config_ != VA_INVALID_ID) vaDestroyConfig(dpy_, config_);
}

Status Vpp::Ensure(VADisplay dpy) {
  if (context_ != VA_INVALID_ID) return Status::kOk;
  dpy_ = dpy;
  VAStatus st = vaCreateConfig(dpy, VAProfileNone, VAEntrypointVideoProc, nullptr, 0, &config_);
  if (st != VA_STATUS_SUCCESS) {
    LogErrorf("VPP config: %s", vaErrorStr(st));
    config_ = VA_INVALID_ID;
    return Status::kVaError;
  }
  st = vaCreateContext(dpy, config_, 0, 0, 0, nullptr, 0, &context_);
  if (st != VA_STATUS_SUCCESS) {
    LogErrorf("VPP context: %s", vaErrorStr(st));
    vaDestroyConfig(dpy, config_);
    config_ = VA_INVALID_ID;
    context_ = VA_INVALID_ID;
    return Status::kVaError;
  }
  return Status::kOk;
}

Status Vpp::Run(VADisplay dpy, VASurfaceID src, const VARectangle& src_rect, VASurfaceID dst,
                const VARectangle& dst_rect, const VppColor& color) {
  std::lock_guard<std::mutex> lock(mutex_);
  Status s = Ensure(dpy);
  if (s != Status::kOk) return s;
  VAProcPipelineParameterBuffer p;
  memset(&p, 0, sizeof(p));
  VARectangle sr = src_rect, dr = dst_rect;
  p.surface = src;
  p.surface_region = &sr;
  p.output_region = &dr;
  p.output_background_color = 0xff000000;
  FillVppColor(color, &p);
  p.filter_flags = VA_FILTER_SCALING_DEFAULT;
  VABufferID buf = VA_INVALID_ID;
  VAStatus st = vaCreateBuffer(dpy, context_, VAProcPipelineParameterBufferType, sizeof(p), 1, &p, &buf);
  if (st != VA_STATUS_SUCCESS) {
    LogErrorf("VPP parameter buffer: %s", vaErrorStr(st));
    return Status::kVaError;
  }
  st = vaBeginPicture(dpy, context_, dst);
  if (st == VA_STATUS_SUCCESS) {
    st = vaRenderPicture(dpy, context_, &buf, 1);
    VAStatus end = vaEndPicture(dpy, context_);
    if (st == VA_STATUS_SUCCESS) st = end;
  }
  vaDestroyBuffer(dpy, buf);
  if (st == VA_STATUS_SUCCESS) st = vaSyncSurface(dpy, dst);
  if (st != VA_STATUS_SUCCESS) {
    LogErrorf("VPP run: %s", vaErrorStr(st));
    return Status::kVaError;
  }
  return Status::kOk;
}

}
