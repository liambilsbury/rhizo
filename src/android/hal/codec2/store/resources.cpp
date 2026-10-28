#include "resources.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

#include <algorithm>
#include <sstream>
#include <vector>

#include "log.h"

namespace rhizo::c2store {

namespace {

std::mutex g_capacity_mu;
std::map<uint32_t, uint64_t>& CapacityTable() {
  static std::map<uint32_t, uint64_t> table;
  return table;
}

double ChargedRate(float frame_rate, float operating_rate) {
  if (operating_rate > 0) return operating_rate;
  if (frame_rate > 0) return frame_rate;
  return 30.0;
}

}

std::map<std::string, uint64_t> ParseCapacity(const std::string& text) {
  std::map<std::string, uint64_t> out;
  std::istringstream lines(text);
  std::string line;
  while (std::getline(lines, line)) {
    std::string::size_type hash = line.find('#');
    if (hash != std::string::npos) line.resize(hash);
    std::istringstream fields(line);
    std::string name, rate, extra;
    if (!(fields >> name)) continue;
    if (!(fields >> rate) || (fields >> extra)) {
      klogf("capacity: malformed line for %s, left out", name.c_str());
      continue;
    }
    char* end = nullptr;
    errno = 0;
    unsigned long long v = strtoull(rate.c_str(), &end, 10);
    if (end == rate.c_str() || *end != '\0' || v == 0 || rate[0] == '-' || errno == ERANGE) {
      klogf("capacity: %s has no usable rate (%s), left out", name.c_str(), rate.c_str());
      continue;
    }
    out[name] = v;
  }
  return out;
}

std::map<std::string, uint64_t> LoadCapacity(const char* path) {
  FILE* f = fopen(path, "re");
  if (f == nullptr) return {};
  std::string text;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) text.append(buf, n);
  fclose(f);
  return ParseCapacity(text);
}

void SetThroughputCapacity(uint32_t id, uint64_t capacity) {
  std::lock_guard<std::mutex> lock(g_capacity_mu);
  CapacityTable()[id] = capacity;
}

uint64_t ThroughputCapacity(uint32_t id) {
  std::lock_guard<std::mutex> lock(g_capacity_mu);
  auto it = CapacityTable().find(id);
  return it == CapacityTable().end() ? 0 : it->second;
}

uint64_t ThroughputNeed(uint64_t capacity, uint32_t width, uint32_t height, float frame_rate, float operating_rate) {
  double need = double(width) * double(height) * ChargedRate(frame_rate, operating_rate);
  if (!(need >= 0)) return 0;
  if (need >= double(capacity)) return capacity;
  return static_cast<uint64_t>(need);
}

std::shared_ptr<C2ResourcesNeededTuning> InstanceResources(uint32_t instance_id, uint32_t width, uint32_t height,
                                                           float frame_rate, float operating_rate) {
  std::vector<C2SystemResourceStruct> needs = {C2SystemResourceStruct(instance_id, C2Config::CONST, 1)};
  uint32_t throughput_id = instance_id + kThroughputIdOffset;
  uint64_t capacity = ThroughputCapacity(throughput_id);
  if (capacity > 0) {
    needs.emplace_back(throughput_id, C2Config::CONST,
                       ThroughputNeed(capacity, width, height, frame_rate, operating_rate));
  }
  return C2ResourcesNeededTuning::AllocShared(needs.size(), needs);
}

C2R UpdateNeeds(C2InterfaceHelper::C2P<C2ResourcesNeededTuning>& me, uint32_t width, uint32_t height,
                float frame_rate, float operating_rate) {
  for (size_t i = 0; i < me.v.flexCount(); ++i) {
    const C2SystemResourceStruct& r = me.v.m.values[i];
    if (!IsThroughputId(r.id)) continue;
    uint64_t need = ThroughputNeed(ThroughputCapacity(r.id), width, height, frame_rate, operating_rate);
    if (need != r.amount) me.set().m.values[i].amount = need;
  }
  return C2R::Ok();
}

uint64_t ThroughputPart(const C2ResourcesNeededTuning& needs) {
  uint64_t sum = 0;
  for (size_t i = 0; i < needs.flexCount(); ++i) {
    if (IsThroughputId(needs.m.values[i].id)) sum += needs.m.values[i].amount;
  }
  return sum;
}

bool ThroughputLedger::Take(uint64_t amount) {
  std::lock_guard<std::mutex> lock(mu_);
  if (amount > capacity_ || held_ > capacity_ - amount) return false;
  held_ += amount;
  return true;
}

void ThroughputLedger::Force(uint64_t amount) {
  std::lock_guard<std::mutex> lock(mu_);
  held_ += amount;
}

void ThroughputLedger::Give(uint64_t amount) {
  std::lock_guard<std::mutex> lock(mu_);
  held_ = held_ >= amount ? held_ - amount : 0;
}

uint64_t ThroughputLedger::held() const {
  std::lock_guard<std::mutex> lock(mu_);
  return held_;
}

}
