// print the c2.rhizo.* components the VA driver offers as a JSON object

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <string>

#include "tools/functional/functional.h"
#include "tools/measure/measure.h"
#include "va/log.h"
#include "va/runtime.h"

using namespace rhizo::c2va;

namespace {

void Usage() {
  fprintf(stderr,
          "usage: rhizo-codec2-probe (--node PATH | --fd N) [--quiet] [--no-functional] [--clip-timeout-ms N]\n"
          "                          [--measure [--measure-budget-ms N] [--measure-clips DIR] [--measure-no-draw]\n"
          "                          [--measure-dump DIR] [--measure-window-ms N] [--measure-step-ms N]\n"
          "                          [--measure-loops] [--measure-encode-frames N]]\n");
}

}

int main(int argc, char** argv) {
  std::string node;
  int fd = -1;
  bool quiet = false, functional = true, measure = false;
  FunctionalOptions options;
  MeasureOptions measure_options;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--node") && i + 1 < argc) {
      node = argv[++i];
    } else if (!strcmp(argv[i], "--fd") && i + 1 < argc) {
      char* end = nullptr;
      long v = strtol(argv[++i], &end, 10);
      if (!end || *end || v < 0 || v > 65535) {
        Usage();
        return 2;
      }
      fd = static_cast<int>(v);
    } else if (!strcmp(argv[i], "--clip-timeout-ms") && i + 1 < argc) {
      char* end = nullptr;
      long v = strtol(argv[++i], &end, 10);
      if (!end || *end || v < 1 || v > 60000) {
        Usage();
        return 2;
      }
      options.clip_timeout_ms = static_cast<uint32_t>(v);
    } else if (!strcmp(argv[i], "--measure-budget-ms") && i + 1 < argc) {
      char* end = nullptr;
      long v = strtol(argv[++i], &end, 10);
      if (!end || *end || v < 1 || v > 120000) {
        Usage();
        return 2;
      }
      measure_options.budget_ms = static_cast<uint32_t>(v);
    } else if ((!strcmp(argv[i], "--measure-window-ms") || !strcmp(argv[i], "--measure-step-ms")) && i + 1 < argc) {
      bool window = !strcmp(argv[i], "--measure-window-ms");
      char* end = nullptr;
      long v = strtol(argv[++i], &end, 10);
      if (!end || *end || v < 1 || v > 60000) {
        Usage();
        return 2;
      }
      (window ? measure_options.window_ms : measure_options.step_ms) = static_cast<uint32_t>(v);
    } else if (!strcmp(argv[i], "--measure-encode-frames") && i + 1 < argc) {
      char* end = nullptr;
      long v = strtol(argv[++i], &end, 10);
      if (!end || *end || v < 1 || v > 10000) {
        Usage();
        return 2;
      }
      measure_options.encode_frames = static_cast<uint32_t>(v);
    } else if (!strcmp(argv[i], "--measure-loops")) {
      measure_options.record_loops = true;
    } else if (!strcmp(argv[i], "--measure")) {
      measure = true;
    } else if (!strcmp(argv[i], "--measure-clips") && i + 1 < argc) {
      measure_options.clip_dir = argv[++i];
    } else if (!strcmp(argv[i], "--measure-dump") && i + 1 < argc) {
      measure_options.dump_dir = argv[++i];
    } else if (!strcmp(argv[i], "--measure-no-draw")) {
      measure_options.draw = false;
    } else if (!strcmp(argv[i], "--quiet")) {
      quiet = true;
    } else if (!strcmp(argv[i], "--no-functional")) {
      functional = false;
    } else {
      Usage();
      return 2;
    }
  }
  if (node.empty() == (fd < 0)) {
    Usage();
    return 2;
  }
  SetLogTarget(quiet ? LogTarget::kNone : LogTarget::kStderr);
  VaDevice& device = VaDevice::Get();
  if (fd >= 0) {
    device.SetFd(fd);
  } else {
    device.SetNode(node);
  }
  Status st = Status::kOk;
  std::shared_ptr<Display> display = device.Acquire(&st);
  if (!display) return 1;
  std::vector<ComponentCaps> components = QueryComponents(display->va());
  for (const auto& c : components) {
    if (!c.min_from_driver) {
      Logf("%s: the driver reports no minimum size; %ux%u is radeonsi's floor", c.name.c_str(), c.min_width,
           c.min_height);
    }
  }
  std::vector<DroppedComponent> dropped;
  bool wedged = false;
  if (functional) {
    FunctionalReport report = ApplyFunctionalChecks(&components, &dropped, device, options);
    for (const std::string& line : report.log) Logf("functional %s", line.c_str());
    Logf("functional checks: %u ms%s", report.total_ms,
         report.wedged ? ", a clip timed out: exiting without closing the display" : "");
    wedged = report.wedged;
  }
  std::string measurements;
  if (measure && !wedged) {
    MeasureReport report = MeasureComponents(components, device, measure_options);
    for (const std::string& line : report.log) Logf("measure %s", line.c_str());
    for (const std::string& line : report.skipped) Logf("measure skipped %s", line.c_str());
    Logf("measurements: %u ms%s", report.elapsed_ms, report.complete ? "" : ", the budget ran out");
    measurements = MeasurementsJson(report);
  }
  std::string json =
      ComponentsJson(display->vendor(), display->major(), display->minor(), components, dropped, measurements);
  bool printed = printf("%s\n", json.c_str()) >= 0 && fflush(stdout) == 0;
  // closing the display can hang behind a timed-out decode thread
  if (wedged) _exit(printed ? 0 : 1);
  display.reset();
  return printed ? 0 : 1;
}
