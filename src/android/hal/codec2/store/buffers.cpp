#include "buffers.h"

#include <C2AllocatorGralloc.h>
#include <cutils/native_handle.h>

#include <rhizo/buffer_metadata.h>

namespace rhizo::c2store {

namespace {

bool Yuv420Planes(const C2GraphicView& view, int32_t* bytes_per_sample) {
  const C2PlanarLayout& l = view.layout();
  if (l.type != C2PlanarLayout::TYPE_YUV || l.numPlanes < 3) return false;
  const C2PlaneInfo& y = l.planes[C2PlanarLayout::PLANE_Y];
  const C2PlaneInfo& u = l.planes[C2PlanarLayout::PLANE_U];
  const C2PlaneInfo& v = l.planes[C2PlanarLayout::PLANE_V];
  if (y.colSampling != 1 || y.rowSampling != 1) return false;
  if (u.colSampling != 2 || u.rowSampling != 2 || v.colSampling != 2 || v.rowSampling != 2) return false;
  if (y.allocatedDepth != u.allocatedDepth || y.allocatedDepth != v.allocatedDepth) return false;
  if (y.allocatedDepth != 8 && y.allocatedDepth != 16) return false;
  *bytes_per_sample = static_cast<int32_t>(y.allocatedDepth / 8);
  return true;
}

}

bool DmabufOf(const C2Block2D& block, c2va::DmabufImage* out) {
  native_handle_t* nh = android::UnwrapNativeCodec2GrallocHandle(block.handle());
  if (nh == nullptr) return false;
  rhizo::DecodedHandle d = rhizo::Decode(nh);
  int fds[rhizo::kMaxFds] = {-1, -1, -1, -1};
  for (int i = 0; i < nh->numFds && i < rhizo::kMaxFds; i++) fds[i] = nh->data[i];
  native_handle_delete(nh);
  if (!d.valid || fds[0] < 0 || d.width <= 0 || d.height <= 0 || d.stride <= 0) return false;
  c2va::DmabufImage img{};
  img.fd = fds[0];
  img.drm_fourcc = static_cast<uint32_t>(d.drmFourcc);
  img.modifier = d.modifier;
  img.width = static_cast<uint32_t>(d.width);
  img.height = static_cast<uint32_t>(d.height);
  if (d.drmFourcc == rhizo::kDrmFormatYvu420) {
    if (d.numPlanes != 3) return false;
    img.num_planes = 3;
    img.num_objects = d.planeFds;
    for (int i = 0; i < d.planeFds; i++) img.object_fds[i] = fds[i];
    for (int p = 0; p < 3; p++) {
      img.pitches[p] = static_cast<uint32_t>(d.planes[p].stride);
      img.offsets[p] = static_cast<uint32_t>(d.planes[p].offset);
      img.plane_object[p] = static_cast<uint32_t>(d.planes[p].fdIndex);
    }
  } else if (d.drmFourcc == rhizo::kDrmFormatAbgr8888 || d.drmFourcc == rhizo::kDrmFormatXbgr8888 ||
             d.drmFourcc == rhizo::kDrmFormatArgb8888) {
    img.num_planes = 1;
    img.pitches[0] = static_cast<uint32_t>(d.stride);
    img.offsets[0] = 0;
  } else {
    return false;
  }
  *out = img;
  return true;
}

bool YuvDestOf(C2GraphicView& view, c2va::YuvDest* out) {
  int32_t bps = 0;
  if (!Yuv420Planes(view, &bps)) return false;
  const C2PlanarLayout& l = view.layout();
  uint8_t* const* data = view.data();
  auto plane = [&](int ix) {
    return c2va::Plane{data[ix], l.planes[ix].rowInc, l.planes[ix].colInc};
  };
  out->y = plane(C2PlanarLayout::PLANE_Y);
  out->cb = plane(C2PlanarLayout::PLANE_U);
  out->cr = plane(C2PlanarLayout::PLANE_V);
  out->width = static_cast<int32_t>(view.width());
  out->height = static_cast<int32_t>(view.height());
  out->bytes_per_sample = bps;
  return true;
}

bool YuvSrcOf(const C2GraphicView& view, c2va::YuvSrc* out) {
  int32_t bps = 0;
  if (!Yuv420Planes(view, &bps) || bps != 1) return false;
  const C2PlanarLayout& l = view.layout();
  const uint8_t* const* data = view.data();
  auto plane = [&](int ix) {
    return c2va::ConstPlane{data[ix], l.planes[ix].rowInc, l.planes[ix].colInc};
  };
  out->y = plane(C2PlanarLayout::PLANE_Y);
  out->cb = plane(C2PlanarLayout::PLANE_U);
  out->cr = plane(C2PlanarLayout::PLANE_V);
  out->width = static_cast<int32_t>(view.width());
  out->height = static_cast<int32_t>(view.height());
  return true;
}

bool RgbaSrcOf(const C2GraphicView& view, c2va::RgbaSrc* out) {
  const C2PlanarLayout& l = view.layout();
  if (l.type != C2PlanarLayout::TYPE_RGBA || l.numPlanes < 4 || l.rootPlanes != 1) return false;
  const C2PlaneInfo& r = l.planes[C2PlanarLayout::PLANE_R];
  if (r.colInc != 4 || r.allocatedDepth != 8) return false;
  const uint8_t* const* data = view.data();
  if (data[C2PlanarLayout::PLANE_G] != data[C2PlanarLayout::PLANE_R] + 1 ||
      data[C2PlanarLayout::PLANE_B] != data[C2PlanarLayout::PLANE_R] + 2 ||
      data[C2PlanarLayout::PLANE_A] != data[C2PlanarLayout::PLANE_R] + 3) {
    return false;
  }
  out->data = data[C2PlanarLayout::PLANE_R];
  out->row_stride = r.rowInc;
  out->width = static_cast<int32_t>(view.width());
  out->height = static_cast<int32_t>(view.height());
  return true;
}

}
