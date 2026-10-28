#include "store.h"

#include <string.h>

#include "log.h"

namespace rhizo::c2store {

Store::Interface::Interface(const std::shared_ptr<C2ReflectorHelper>& helper,
                            const std::vector<C2SystemResourceStruct>& capacity)
    : C2InterfaceHelper(helper) {
  setDerivedInstance(this);
  helper->addStructDescriptors<C2SystemResourceStruct>();

  addParameter(DefineParam(ion_usage_, "ion-usage")
                   .withDefault(new C2StoreIonUsageInfo())
                   .withFields({C2F(ion_usage_, usage).flags({C2MemoryUsage::CPU_READ | C2MemoryUsage::CPU_WRITE}),
                                C2F(ion_usage_, capacity).inRange(0, UINT32_MAX, 1024),
                                C2F(ion_usage_, heapMask).any(), C2F(ion_usage_, allocFlags).flags({}),
                                C2F(ion_usage_, minAlignment).equalTo(0)})
                   .withSetter(SetIonUsage)
                   .build());

  addParameter(DefineParam(dmabuf_usage_, "dmabuf-usage")
                   .withDefault(C2StoreDmaBufUsageInfo::AllocShared(128))
                   .withFields({C2F(dmabuf_usage_, m.usage).flags({C2MemoryUsage::CPU_READ | C2MemoryUsage::CPU_WRITE}),
                                C2F(dmabuf_usage_, m.capacity).inRange(0, UINT32_MAX, 1024),
                                C2F(dmabuf_usage_, m.allocFlags).flags({}), C2F(dmabuf_usage_, m.heapName).any()})
                   .withSetter(SetDmaBufUsage)
                   .build());

  addParameter(DefineParam(resources_capacity_, C2_PARAMKEY_RESOURCES_CAPACITY)
                   .withConstValue(C2ResourcesCapacityTuning::AllocShared(capacity.size(), capacity))
                   .build());

  addParameter(DefineParam(resources_excluded_, C2_PARAMKEY_RESOURCES_EXCLUDED)
                   .withConstValue(C2ResourcesExcludedTuning::AllocShared(0))
                   .build());
}

C2R Store::Interface::SetIonUsage(bool, C2P<C2StoreIonUsageInfo>& me) {
  me.set().heapMask = ~0;
  me.set().allocFlags = 0;
  me.set().minAlignment = 0;
  return C2R::Ok();
}

// map all usages to the system heap
C2R Store::Interface::SetDmaBufUsage(bool, C2P<C2StoreDmaBufUsageInfo>& me) {
  strncpy(me.set().m.heapName, "system", me.v.flexCount());
  me.set().m.allocFlags = 0;
  return C2R::Ok();
}

// list the resource capacities and record the throughput capacities
std::vector<C2SystemResourceStruct> Store::CapacityOf(const std::vector<ComponentEntry>& entries) {
  std::vector<C2SystemResourceStruct> out;
  for (const ComponentEntry& e : entries) {
    if (!e.traits || !e.make_interface || !e.make_component || e.max_instances == 0) continue;
    bool seen = false;
    for (const C2SystemResourceStruct& r : out) seen = seen || r.id == e.resource_id;
    if (seen) continue;
    out.emplace_back(e.resource_id, C2Config::CONST, e.max_instances);
    SetThroughputCapacity(e.resource_id + kThroughputIdOffset, e.pixel_rate);
    if (e.pixel_rate > 0) out.emplace_back(e.resource_id + kThroughputIdOffset, C2Config::CONST, e.pixel_rate);
  }
  return out;
}

bool InstanceSlot::Reserve(uint64_t amount) {
  std::lock_guard<std::mutex> lock(mu_);
  if (!ledger_) return true;
  ledger_->Give(reserved_);
  reserved_ = 0;
  if (!ledger_->Take(amount)) return false;
  reserved_ = amount;
  return true;
}

void InstanceSlot::Adjust(uint64_t amount) {
  std::lock_guard<std::mutex> lock(mu_);
  if (!ledger_) return;
  ledger_->Give(reserved_);
  ledger_->Force(amount);
  reserved_ = amount;
}

void InstanceSlot::Unreserve() {
  std::lock_guard<std::mutex> lock(mu_);
  if (ledger_) ledger_->Give(reserved_);
  reserved_ = 0;
}

uint64_t InstanceSlot::reserved() const {
  std::lock_guard<std::mutex> lock(mu_);
  return reserved_;
}

c2_status_t ReserveAtStart(InstanceSlot* slot, const C2ResourcesNeededTuning& needs, const std::string& name) {
  if (slot == nullptr) return C2_BAD_STATE;
  uint64_t need = ThroughputPart(needs);
  if (!slot->Reserve(need)) {
    klogf("store: %s refused at start: %llu luma samples/s do not fit the component's throughput", name.c_str(),
          static_cast<unsigned long long>(need));
    return C2_NO_MEMORY;
  }
  return C2_OK;
}

c2_status_t StartReserved(InstanceSlot* slot, const C2ResourcesNeededTuning& needs, const std::string& name,
                          const std::function<c2_status_t()>& start) {
  if (slot == nullptr) return C2_BAD_STATE;
  if (slot->reserved() > 0) return start();
  c2_status_t err = ReserveAtStart(slot, needs, name);
  if (err != C2_OK) return err;
  err = start();
  if (err != C2_OK) slot->Unreserve();
  return err;
}

bool HoldNeeds(InstanceSlot* slot, const C2ResourcesNeededTuning& needs, bool force) {
  if (slot == nullptr) return false;
  uint64_t throughput = ThroughputPart(needs);
  if (throughput == slot->reserved() && !force) return false;
  slot->Adjust(throughput);
  return true;
}

Store::Store(std::vector<ComponentEntry> entries)
    : reflector_(std::make_shared<C2ReflectorHelper>()), interface_(reflector_, CapacityOf(entries)) {
  for (ComponentEntry& e : entries) {
    if (!e.traits || !e.make_interface || !e.make_component || e.max_instances == 0) {
      klogf("store: dropping an incomplete registry entry (%s)", e.traits ? e.traits->name.c_str() : "?");
      continue;
    }
    std::string name = e.traits->name;
    if (slots_.count(name) != 0) {
      klogf("store: dropping a second registry entry named %s", name.c_str());
      continue;
    }
    traits_.push_back(e.traits);
    klogf("store: offers %s (%s, rank %u, at most %u instances: resource %u; throughput %llu/s: resource %u)",
          name.c_str(), e.traits->mediaType.c_str(), static_cast<unsigned>(e.traits->rank), e.max_instances,
          e.resource_id, static_cast<unsigned long long>(e.pixel_rate),
          e.pixel_rate > 0 ? e.resource_id + kThroughputIdOffset : 0);
    std::shared_ptr<ThroughputLedger> ledger =
        e.pixel_rate > 0 ? std::make_shared<ThroughputLedger>(e.pixel_rate) : nullptr;
    slots_.emplace(name, Slot{std::move(e), std::make_shared<std::atomic<uint32_t>>(0), std::move(ledger)});
  }
  if (slots_.empty()) klogf("store: offers no components");
}

C2String Store::getName() const { return "default"; }

const Store::Slot* Store::find(const std::string& name) const {
  auto it = slots_.find(name);
  return it == slots_.end() ? nullptr : &it->second;
}

c2_status_t Store::createComponent(C2String name, std::shared_ptr<C2Component>* const component) {
  component->reset();
  const Slot* slot = find(name);
  if (slot == nullptr) return C2_NOT_FOUND;
  uint32_t live = slot->live->load();
  do {
    if (live >= slot->entry.max_instances) {
      klogf("store: %s refused: %u of %u instances live", name.c_str(), live, slot->entry.max_instances);
      return C2_NO_MEMORY;
    }
  } while (!slot->live->compare_exchange_weak(live, live + 1));
  auto token = std::make_unique<InstanceSlot>(slot->live, slot->ledger);
  std::shared_ptr<C2Component> made = slot->entry.make_component(next_node_id_++, reflector_, std::move(token));
  if (!made) {
    klogf("store: %s could not be created", name.c_str());
    return C2_NO_MEMORY;
  }
  *component = std::move(made);
  return C2_OK;
}

// create a component interface without an instance slot
c2_status_t Store::createInterface(C2String name, std::shared_ptr<C2ComponentInterface>* const interface) {
  interface->reset();
  const Slot* slot = find(name);
  if (slot == nullptr) return C2_NOT_FOUND;
  std::shared_ptr<C2ComponentInterface> made = slot->entry.make_interface(next_node_id_++, reflector_);
  if (!made) return C2_CORRUPTED;
  *interface = std::move(made);
  return C2_OK;
}

std::vector<std::shared_ptr<const C2Component::Traits>> Store::listComponents() { return traits_; }

c2_status_t Store::copyBuffer(std::shared_ptr<C2GraphicBuffer>, std::shared_ptr<C2GraphicBuffer>) {
  return C2_OMITTED;
}

c2_status_t Store::query_sm(const std::vector<C2Param*>& stackParams,
                            const std::vector<C2Param::Index>& heapParamIndices,
                            std::vector<std::unique_ptr<C2Param>>* const heapParams) const {
  return interface_.query(stackParams, heapParamIndices, C2_MAY_BLOCK, heapParams);
}

c2_status_t Store::config_sm(const std::vector<C2Param*>& params,
                             std::vector<std::unique_ptr<C2SettingResult>>* const failures) {
  return interface_.config(params, C2_MAY_BLOCK, failures);
}

std::shared_ptr<C2ParamReflector> Store::getParamReflector() const { return reflector_; }

c2_status_t Store::querySupportedParams_nb(std::vector<std::shared_ptr<C2ParamDescriptor>>* const params) const {
  return interface_.querySupportedParams(params);
}

c2_status_t Store::querySupportedValues_sm(std::vector<C2FieldSupportedValuesQuery>& fields) const {
  return interface_.querySupportedValues(fields, C2_MAY_BLOCK);
}

uint32_t Store::live(const std::string& name) const {
  const Slot* slot = find(name);
  return slot == nullptr ? 0 : slot->live->load();
}

uint64_t Store::throughput_held(const std::string& name) const {
  const Slot* slot = find(name);
  return slot == nullptr || !slot->ledger ? 0 : slot->ledger->held();
}

std::shared_ptr<const C2Component::Traits> VideoTraits(const std::string& name, const std::string& media_type,
                                                       C2Component::kind_t kind) {
  auto t = std::make_shared<C2Component::Traits>();
  t->name = name;
  t->domain = C2Component::DOMAIN_VIDEO;
  t->kind = kind;
  t->rank = kRank;
  t->mediaType = media_type;
  t->owner = "default";
  return t;
}

}
