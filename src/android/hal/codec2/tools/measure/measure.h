#ifndef RHIZO_C2VA_MEASURE_H
#define RHIZO_C2VA_MEASURE_H

// measure each component's throughput at a ladder of sizes

#include <stddef.h>
#include <stdint.h>

#include <map>
#include <string>
#include <vector>

#include "va/runtime.h"

namespace rhizo::c2va {

struct MeasureOptions {
  uint32_t budget_ms = 25000;
  uint32_t encode_frames = 30;
  uint32_t step_ms = 3000;
  uint32_t warmup_frames = 10;
  uint32_t warmup_ms = 100;
  uint32_t window_frames = 60;
  uint32_t window_ms = 300;
  double settle = 0.03;
  uint32_t settle_min_pixels = 1920 * 1080;
  uint32_t small_window_ms = 150;
  uint32_t encode_warmup_frames = 10;
  uint32_t encode_window_frames = 30;
  uint32_t input_ring = 4;
  uint32_t min_window_frames = 10;
  std::string clip_dir;
  bool draw = true;
  std::string dump_dir;
  bool record_loops = false;
};

struct Measurement {
  std::string name;
  uint32_t width = 0;
  uint32_t height = 0;
  double fps = 0;
  uint32_t frames = 0;
  uint32_t ms = 0;
  std::string source;
  uint32_t warmup_ms = 0;
  double decode_ms = 0;
  double draw_ms = 0;
  uint32_t stream_kbps = 0;
  std::vector<double> loop_ms;
  bool settled = true;
};

struct MeasureReport {
  uint32_t budget_ms = 0;
  uint32_t elapsed_ms = 0;
  bool complete = true;
  std::vector<Measurement> results;
  std::vector<std::string> skipped;
  std::vector<std::string> log;
  std::map<std::string, double> steps;
};

// return the sizes measured for a component
std::vector<std::pair<uint32_t, uint32_t>> MeasureLadder(const ComponentCaps& caps);

// return the CTS clip bitrate in kbit/s for a codec and size
uint32_t DecodeKbps(Codec codec, uint32_t width, uint32_t height);

// describe a measurement clip from its clips.tsv row
struct MeasureClip {
  std::string file;
  Codec codec;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t frames = 0;
  std::vector<std::vector<uint8_t>> units;
};

// read the clips whose files match their clips.tsv rows
std::vector<MeasureClip> ReadMeasureClips(const std::string& dir, std::vector<std::string>* skipped);

// measure the encoders and the functional decoders of components
MeasureReport MeasureComponents(const std::vector<ComponentCaps>& components, VaDevice& device,
                                const MeasureOptions& options = {});

std::string MeasurementsJson(const MeasureReport& report);

}

#endif
