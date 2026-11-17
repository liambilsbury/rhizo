// the registry of QueryComponents results with a linked core

#include <string.h>

#include <string>

#include "log.h"
#include "registry.h"
#include "va/log.h"
#include "va/runtime.h"
#include "video_decoder.h"
#include "video_encoder.h"

namespace rhizo::c2va {

std::unique_ptr<DecoderCore> CreateH264Decoder(DecoderHost* host) __attribute__((weak));
std::unique_ptr<DecoderCore> CreateHevcDecoder(DecoderHost* host) __attribute__((weak));
std::unique_ptr<DecoderCore> CreateVp9Decoder(DecoderHost* host) __attribute__((weak));
std::unique_ptr<DecoderCore> CreateAv1Decoder(DecoderHost* host) __attribute__((weak));
std::unique_ptr<EncoderCore> CreateH264Encoder(EncoderHost* host, const EncoderConfig& config, Status* status)
    __attribute__((weak));
std::unique_ptr<EncoderCore> CreateHevcEncoder(EncoderHost* host, const EncoderConfig& config, Status* status)
    __attribute__((weak));

}

namespace rhizo::c2store {

namespace {

bool CoreLinked(const c2va::ComponentCaps& caps) {
  using c2va::Codec;
  if (caps.kind == c2va::Kind::kDecoder) {
    switch (caps.codec) {
      case Codec::kAvc: return c2va::CreateH264Decoder != nullptr;
      case Codec::kHevc: return c2va::CreateHevcDecoder != nullptr;
      case Codec::kVp9: return c2va::CreateVp9Decoder != nullptr;
      case Codec::kAv1: return c2va::CreateAv1Decoder != nullptr;
    }
    return false;
  }
  switch (caps.codec) {
    case Codec::kAvc: return c2va::CreateH264Encoder != nullptr;
    case Codec::kHevc: return c2va::CreateHevcEncoder != nullptr;
    default: return false;
  }
}

}

void ConfigureRuntime(int argc, char** argv) {
  for (int i = 1; i + 1 < argc; i++) {
    if (strcmp(argv[i], "--node") == 0) {
      c2va::VaDevice::Get().SetNode(argv[i + 1]);
      klogf("render node %s", argv[i + 1]);
    }
  }
}

std::vector<ComponentEntry> BuildRegistry() {
  c2va::Status st = c2va::Status::kOk;
  std::vector<c2va::ComponentCaps> all = c2va::QueryComponents(c2va::VaDevice::Get(), &st);
  if (st != c2va::Status::kOk) {
    klogf("QueryComponents failed (%d)", static_cast<int>(st));
    return {};
  }
  std::map<std::string, uint64_t> capacity = LoadCapacity(kCapacityPath);
  if (capacity.empty()) klogf("no throughput capacities at %s", kCapacityPath);
  std::vector<ComponentEntry> out;
  for (const c2va::ComponentCaps& caps : all) {
    if (!CoreLinked(caps)) {
      klogf("no core linked for driver component %s", caps.name.c_str());
      continue;
    }
    out.push_back(caps.kind == c2va::Kind::kDecoder ? DecoderEntry(caps) : EncoderEntry(caps));
    auto it = capacity.find(caps.name);
    if (it != capacity.end()) out.back().pixel_rate = it->second;
  }
  return out;
}

}
