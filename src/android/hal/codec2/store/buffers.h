#ifndef RHIZO_C2STORE_BUFFERS_H
#define RHIZO_C2STORE_BUFFERS_H

// Codec2 graphic blocks as VA runtime buffer views

#include <C2Buffer.h>

#include "va/runtime.h"

namespace rhizo::c2store {

// map an RGB or YV12 block to a dmabuf image
bool DmabufOf(const C2Block2D& block, c2va::DmabufImage* out);

// map a YUV 4:2:0 view to a YUV destination
bool YuvDestOf(C2GraphicView& view, c2va::YuvDest* out);
// map an 8-bit YUV 4:2:0 view to a YUV source
bool YuvSrcOf(const C2GraphicView& view, c2va::YuvSrc* out);
// map an RGBA_8888 view to an RGBA source
bool RgbaSrcOf(const C2GraphicView& view, c2va::RgbaSrc* out);

}

#endif
