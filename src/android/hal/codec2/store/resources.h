#ifndef RHIZO_C2STORE_RESOURCES_H
#define RHIZO_C2STORE_RESOURCES_H

// the Codec2 instance and throughput resources

#include <stdint.h>

#include <map>
#include <memory>
#include <mutex>
#include <string>

#include <C2Config.h>
#include <util/C2InterfaceHelper.h>

namespace rhizo::c2store {

constexpr uint32_t kResourceIdDecoderBase = C2PlatformConfig::VENDOR_START;
constexpr uint32_t kResourceIdEncoderBase = C2PlatformConfig::VENDOR_START + 0x10;
constexpr uint32_t kThroughputIdOffset = 0x100;

inline bool IsThroughputId(uint32_t id) {
  return id >= C2PlatformConfig::VENDOR_START + kThroughputIdOffset &&
         id < C2PlatformConfig::VENDOR_START + 2 * kThroughputIdOffset;
}

constexpr char kCapacityPath[] = "/vendor/etc/rhizo-codec2-capacity.conf";

// parse the capacity file's text into rates by component name
std::map<std::string, uint64_t> ParseCapacity(const std::string& text);
// read and parse the capacity file
std::map<std::string, uint64_t> LoadCapacity(const char* path);

// set a throughput resource's capacity
void SetThroughputCapacity(uint32_t id, uint64_t capacity);
uint64_t ThroughputCapacity(uint32_t id);

// return the luma sample rate needed, capped at capacity
uint64_t ThroughputNeed(uint64_t capacity, uint32_t width, uint32_t height, float frame_rate, float operating_rate);

// return a component's resource needs at a size and rate
std::shared_ptr<C2ResourcesNeededTuning> InstanceResources(uint32_t instance_id, uint32_t width, uint32_t height,
                                                           float frame_rate, float operating_rate);
// set the throughput needs from size and rate
C2R UpdateNeeds(C2InterfaceHelper::C2P<C2ResourcesNeededTuning>& me, uint32_t width, uint32_t height,
                float frame_rate, float operating_rate);
uint64_t ThroughputPart(const C2ResourcesNeededTuning& needs);

// track the throughput a component's started instances hold
class ThroughputLedger {
 public:
  explicit ThroughputLedger(uint64_t capacity) : capacity_(capacity) {}

  // take amount when it fits within capacity
  bool Take(uint64_t amount);
  // take amount past capacity
  void Force(uint64_t amount);
  void Give(uint64_t amount);
  uint64_t held() const;
  uint64_t capacity() const { return capacity_; }

 private:
  const uint64_t capacity_;
  mutable std::mutex mu_;
  uint64_t held_ = 0;
};

}

#endif
