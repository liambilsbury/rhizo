#ifndef RHIZO_C2VA_AV1_DECODER_H
#define RHIZO_C2VA_AV1_DECODER_H

// the AV1 decoder core on VA

#include <memory>

#include <va/va.h>
#include <va/va_dec_av1.h>

#include "dec/av1/av1_bits.h"
#include "dec/av1/av1_syntax.h"
#include "va/core.h"

namespace rhizo::c2va {

std::unique_ptr<DecoderCore> CreateAv1DecoderWithTrace(DecoderHost* host, av1::Trace* trace);

namespace av1 {

void FillPictureParameters(const SequenceHeader& seq, const FrameHeader& h, const VASurfaceID refs[kNumRefFrames],
                           VASurfaceID current, VASurfaceID display, bool grain, VADecPictureParameterBufferAV1* pp);

// return false for virgl drivers that drop the film-grain target
bool DriverAppliesGrain(const char* vendor);

// return operating point 0's spatial layer count
int SpatialLayers(const SequenceHeader& seq);

StreamInfo StreamInfoFor(const SequenceHeader& seq, bool grain_applies);

}
}

#endif
