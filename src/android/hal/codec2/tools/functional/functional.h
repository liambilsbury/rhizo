#ifndef RHIZO_C2VA_FUNCTIONAL_H
#define RHIZO_C2VA_FUNCTIONAL_H

// check that each decoder decodes its clip to the reference frames

#include <stdint.h>

#include <string>
#include <vector>

#include "tools/functional/clips.h"
#include "va/runtime.h"

namespace rhizo::c2va {

struct FunctionalOptions {
  uint32_t clip_timeout_ms = 2000;
};

struct FunctionalReport {
  uint32_t total_ms = 0;
  bool wedged = false;
  std::vector<std::string> log;
};

// check a clip on a worker thread with a timeout
std::string CheckClip(const FunctionalClip& clip, VaDevice& device, uint32_t timeout_ms, bool* timed_out);

// drop the decoders and 10-bit profiles whose clips fail
FunctionalReport ApplyFunctionalChecks(std::vector<ComponentCaps>* components, std::vector<DroppedComponent>* dropped,
                                       VaDevice& device, const FunctionalOptions& options = {});

}

#endif
