// serve IComponentStore/default for the c2.rhizo.* VA-API video codecs

#include <signal.h>
#include <stdlib.h>

#include <memory>
#include <string>

#include <android/binder_manager.h>
#include <android/binder_process.h>

#include <codec2/aidl/ComponentStore.h>
#include <codec2/common/HalSelection.h>

#include "log.h"
#include "registry.h"
#include "sandbox.h"
#include "store.h"

namespace {

constexpr int kThreadCount = 8;

}

int main(int argc, char** argv) {
  using ::aidl::android::hardware::media::c2::IComponentStore;
  using rhizo::c2store::klogf;

  signal(SIGPIPE, SIG_IGN);

  if (!::android::IsCodec2AidlHalSelected()) {
    klogf("service: the AIDL Codec2 HAL is not selected (media.c2.hal.selection), not starting");
    return 1;
  }

  if (!rhizo::c2store::EnterSandbox()) {
    klogf("service: the seccomp sandbox could not be entered, not starting");
    return 1;
  }

  rhizo::c2store::ConfigureRuntime(argc, argv);

  ABinderProcess_setThreadPoolMaxThreadCount(kThreadCount);
  ABinderProcess_startThreadPool();

  std::shared_ptr<IComponentStore> store = ::ndk::SharedRefBase::make<
      ::aidl::android::hardware::media::c2::utils::ComponentStore>(
      std::make_shared<rhizo::c2store::Store>(rhizo::c2store::BuildRegistry()));
  if (store == nullptr) {
    klogf("service: cannot create the IComponentStore");
    return 1;
  }
  const std::string instance = std::string(IComponentStore::descriptor) + "/default";
  binder_exception_t ex = AServiceManager_addService(store->asBinder().get(), instance.c_str());
  if (ex != EX_NONE) {
    klogf("service: cannot register %s (exception %d)", instance.c_str(), static_cast<int>(ex));
    return 1;
  }
  klogf("service: %s registered", instance.c_str());

  ABinderProcess_joinThreadPool();
  return 0;
}
