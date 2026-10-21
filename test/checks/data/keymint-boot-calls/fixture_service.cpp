#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern "C" {
struct AIBinder;
struct AIBinder_Class;
struct AParcel;
struct AStatus;
typedef int32_t binder_status_t;
typedef binder_status_t (*OnTransact)(AIBinder*, uint32_t, const AParcel*, AParcel*);
AIBinder_Class* AIBinder_Class_define(const char*, void* (*)(void*), void (*)(void*), OnTransact);
AIBinder* AIBinder_new(const AIBinder_Class*, void*);
int32_t AServiceManager_addService(AIBinder*, const char*);
bool ABinderProcess_setThreadPoolMaxThreadCount(uint32_t);
void ABinderProcess_joinThreadPool();
AStatus* AStatus_newOk();
AStatus* AStatus_fromServiceSpecificError(int32_t);
void AStatus_delete(AStatus*);
binder_status_t AParcel_writeStatusHeader(AParcel*, const AStatus*);
binder_status_t AParcel_writeInt32(AParcel*, int32_t);
}

static void* onCreate(void* args) { return args; }
static void onDestroy(void*) {}

static binder_status_t ok(AParcel* out) {
  AStatus* s = AStatus_newOk();
  binder_status_t st = AParcel_writeStatusHeader(out, s);
  AStatus_delete(s);
  return st;
}

// write the KeyMint reply status
static binder_status_t keymint(AIBinder*, uint32_t code, const AParcel*, AParcel* out) {
#ifdef REFUSE_GENERATE_KEY
  if (code == 3) {
    AStatus* s = AStatus_fromServiceSpecificError(-4);
    binder_status_t st = AParcel_writeStatusHeader(out, s);
    AStatus_delete(s);
    return st;
  }
#endif
  return ok(out);
}

#ifdef CFI_FREE
extern "C" void nocfi_free(void*);
void (*volatile freer)(void*) = nocfi_free;
#endif

// write the shared secret reply status
static binder_status_t sharedSecret(AIBinder*, uint32_t code, const AParcel*, AParcel* out) {
#ifdef TRAP_IN_COMPUTE_SHARED_SECRET
  if (code == 2) __builtin_trap();
#endif
#ifdef CFI_FREE
  if (code == 2) freer(nullptr);
#endif
  binder_status_t st = ok(out);
  if (code == 1) {
    AParcel_writeInt32(out, 1);
    AParcel_writeInt32(out, 4);
  }
  return st;
}

int main() {
  ABinderProcess_setThreadPoolMaxThreadCount(0);
  AServiceManager_addService(
      AIBinder_new(AIBinder_Class_define("android.hardware.security.keymint.IKeyMintDevice",
                                         onCreate, onDestroy, keymint), nullptr),
      "android.hardware.security.keymint.IKeyMintDevice/default");
  AServiceManager_addService(
      AIBinder_new(AIBinder_Class_define("android.hardware.security.sharedsecret.ISharedSecret",
                                         onCreate, onDestroy, sharedSecret), nullptr),
      "android.hardware.security.sharedsecret.ISharedSecret/default");
  ABinderProcess_joinThreadPool();
  return EXIT_FAILURE;
}
