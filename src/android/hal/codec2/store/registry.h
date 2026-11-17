#ifndef RHIZO_C2STORE_REGISTRY_H
#define RHIZO_C2STORE_REGISTRY_H

// the registry of c2.rhizo.* components the running driver supports

#include <stdint.h>

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include <mutex>

#include <C2Component.h>
#include <C2Config.h>
#include <util/C2InterfaceHelper.h>

#include "resources.h"

namespace rhizo::c2store {

// live instance counted against the entry's max_instances
class InstanceSlot {
 public:
  InstanceSlot(std::shared_ptr<std::atomic<uint32_t>> live, std::shared_ptr<ThroughputLedger> ledger)
      : live_(std::move(live)), ledger_(std::move(ledger)) {}
  ~InstanceSlot() {
    Unreserve();
    live_->fetch_sub(1);
  }
  InstanceSlot(const InstanceSlot&) = delete;
  InstanceSlot& operator=(const InstanceSlot&) = delete;

  // replace reserved_ with amount, or return false when ledger_->Take fails
  bool Reserve(uint64_t amount);
  // replace reserved_ with amount through ledger_->Force
  void Adjust(uint64_t amount);
  void Unreserve();
  uint64_t reserved() const;

 private:
  std::shared_ptr<std::atomic<uint32_t>> live_;
  std::shared_ptr<ThroughputLedger> ledger_;
  mutable std::mutex mu_;
  uint64_t reserved_ = 0;
};

// reserve the needed throughput or return C2_NO_MEMORY
c2_status_t ReserveAtStart(InstanceSlot* slot, const C2ResourcesNeededTuning& needs, const std::string& name);
// call start under ReserveAtStart, or Unreserve when start fails
c2_status_t StartReserved(InstanceSlot* slot, const C2ResourcesNeededTuning& needs, const std::string& name,
                          const std::function<c2_status_t()>& start);
// call Adjust and return true when force is set or ThroughputPart(needs) differs from reserved()
bool HoldNeeds(InstanceSlot* slot, const C2ResourcesNeededTuning& needs, bool force);

using InterfaceFactory = std::function<std::shared_ptr<C2ComponentInterface>(
    c2_node_id_t id, const std::shared_ptr<C2ReflectorHelper>& reflector)>;
using ComponentFactory = std::function<std::shared_ptr<C2Component>(
    c2_node_id_t id, const std::shared_ptr<C2ReflectorHelper>& reflector, std::unique_ptr<InstanceSlot> slot)>;

constexpr uint32_t kRank = 256;

struct ComponentEntry {
  std::shared_ptr<const C2Component::Traits> traits;
  uint32_t max_instances;
  uint32_t resource_id;
  uint64_t pixel_rate = 0;
  InterfaceFactory make_interface;
  ComponentFactory make_component;
};

std::shared_ptr<const C2Component::Traits> VideoTraits(const std::string& name, const std::string& media_type,
                                                       C2Component::kind_t kind);

// read the render node VA opens from --node PATH
void ConfigureRuntime(int argc, char** argv);

// build the entries of the components the running driver supports
std::vector<ComponentEntry> BuildRegistry();

}

#endif
