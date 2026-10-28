#ifndef RHIZO_C2VA_HEVC_DECODER_H
#define RHIZO_C2VA_HEVC_DECODER_H

// the HEVC decoder core

#include <memory>

#include "../../va/core.h"
#include "syntax_reader.h"

namespace rhizo::c2va::hevc {

std::unique_ptr<DecoderCore> CreateDecoderWithTrace(DecoderHost* host, TraceSink* trace);

}

#endif
