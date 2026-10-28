#ifndef RHIZO_C2STORE_STORE_H
#define RHIZO_C2STORE_STORE_H

// the component store

#include <stdint.h>

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <C2Component.h>
#include <C2Config.h>
#include <util/C2InterfaceHelper.h>

#include "registry.h"

namespace rhizo::c2store {

class Store : public C2ComponentStore {
 public:
  explicit Store(std::vector<ComponentEntry> entries);
  ~Store() override = default;

  C2String getName() const override;
  c2_status_t createComponent(C2String name, std::shared_ptr<C2Component>* const component) override;
  c2_status_t createInterface(C2String name, std::shared_ptr<C2ComponentInterface>* const interface) override;
  std::vector<std::shared_ptr<const C2Component::Traits>> listComponents() override;
  c2_status_t copyBuffer(std::shared_ptr<C2GraphicBuffer> src, std::shared_ptr<C2GraphicBuffer> dst) override;
  c2_status_t query_sm(const std::vector<C2Param*>& stackParams,
                       const std::vector<C2Param::Index>& heapParamIndices,
                       std::vector<std::unique_ptr<C2Param>>* const heapParams) const override;
  c2_status_t config_sm(const std::vector<C2Param*>& params,
                        std::vector<std::unique_ptr<C2SettingResult>>* const failures) override;
  std::shared_ptr<C2ParamReflector> getParamReflector() const override;
  c2_status_t querySupportedParams_nb(
      std::vector<std::shared_ptr<C2ParamDescriptor>>* const params) const override;
  c2_status_t querySupportedValues_sm(std::vector<C2FieldSupportedValuesQuery>& fields) const override;

  // return a component's live instance count
  uint32_t live(const std::string& name) const;

 private:
  // declare the store's buffer usage and resource parameters
  class Interface : public C2InterfaceHelper {
   public:
    Interface(const std::shared_ptr<C2ReflectorHelper>& helper, const std::vector<C2SystemResourceStruct>& capacity);

   private:
    static C2R SetIonUsage(bool mayBlock, C2P<C2StoreIonUsageInfo>& me);
    static C2R SetDmaBufUsage(bool mayBlock, C2P<C2StoreDmaBufUsageInfo>& me);

    std::shared_ptr<C2StoreIonUsageInfo> ion_usage_;
    std::shared_ptr<C2StoreDmaBufUsageInfo> dmabuf_usage_;
    std::shared_ptr<C2ResourcesCapacityTuning> resources_capacity_;
    std::shared_ptr<C2ResourcesExcludedTuning> resources_excluded_;
  };

  static std::vector<C2SystemResourceStruct> CapacityOf(const std::vector<ComponentEntry>& entries);

  struct Slot {
    ComponentEntry entry;
    std::shared_ptr<std::atomic<uint32_t>> live;
    std::shared_ptr<ThroughputLedger> ledger;
  };

 public:
  // return the throughput a component's instances hold
  uint64_t throughput_held(const std::string& name) const;

 private:

  const Slot* find(const std::string& name) const;

  std::shared_ptr<C2ReflectorHelper> reflector_;
  Interface interface_;
  std::map<std::string, Slot> slots_;
  std::vector<std::shared_ptr<const C2Component::Traits>> traits_;
  std::atomic<c2_node_id_t> next_node_id_{1};
};

}

#endif
