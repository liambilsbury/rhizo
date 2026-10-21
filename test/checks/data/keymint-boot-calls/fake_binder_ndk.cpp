#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <map>
#include <string>
#include <vector>

extern "C" {

typedef int32_t binder_status_t;
typedef int32_t binder_exception_t;
typedef uint32_t transaction_code_t;

enum { STATUS_OK = 0, STATUS_NO_MEMORY = -12, STATUS_BAD_VALUE = -22, STATUS_NOT_ENOUGH_DATA = -61 };
enum { EX_NONE = 0, EX_SERVICE_SPECIFIC = -8 };

struct AParcel {
  std::vector<uint8_t> d;
  size_t pos = 0;
};
struct AStatus {
  int32_t ex = EX_NONE;
  int32_t ss = 0;
  std::string msg;
};
typedef void* (*AIBinder_Class_onCreate)(void* args);
typedef void (*AIBinder_Class_onDestroy)(void* userData);
struct AIBinder;
typedef binder_status_t (*AIBinder_Class_onTransact)(AIBinder* binder, transaction_code_t code,
                                                     const AParcel* in, AParcel* out);
struct AIBinder_Class {
  std::string descriptor;
  AIBinder_Class_onCreate onCreate;
  AIBinder_Class_onDestroy onDestroy;
  AIBinder_Class_onTransact onTransact;
};
struct AIBinder {
  const AIBinder_Class* clazz;
  void* userData;
  int strong;
};
struct AIBinder_Weak {
  AIBinder* b;
};

static void put(AParcel* p, const void* v, size_t n) {
  size_t padded = (n + 3) & ~size_t(3);
  if (p->pos + padded > p->d.size()) p->d.resize(p->pos + padded);
  memcpy(p->d.data() + p->pos, v, n);
  if (padded > n) memset(p->d.data() + p->pos + n, 0, padded - n);
  p->pos += padded;
}
static binder_status_t get(const AParcel* cp, void* v, size_t n) {
  AParcel* p = const_cast<AParcel*>(cp);
  size_t padded = (n + 3) & ~size_t(3);
  if (p->pos + padded > p->d.size()) return STATUS_NOT_ENOUGH_DATA;
  memcpy(v, p->d.data() + p->pos, n);
  p->pos += padded;
  return STATUS_OK;
}

// return an AIBinder_Class from the callbacks
AIBinder_Class* AIBinder_Class_define(const char* descriptor, AIBinder_Class_onCreate onCreate,
                                      AIBinder_Class_onDestroy onDestroy,
                                      AIBinder_Class_onTransact onTransact) {
  return new AIBinder_Class{descriptor, onCreate, onDestroy, onTransact};
}
void AIBinder_Class_setOnDump(AIBinder_Class*, void*) {}
void AIBinder_Class_setHandleShellCommand(AIBinder_Class*, void*) {}
void AIBinder_Class_setTransactionCodeToFunctionNameMap(AIBinder_Class*, const char**, size_t) {}
AIBinder* AIBinder_new(const AIBinder_Class* clazz, void* args) {
  return new AIBinder{clazz, clazz->onCreate(args), 1};
}
void* AIBinder_getUserData(AIBinder* b) { return b->userData; }
void AIBinder_incStrong(AIBinder* b) { b->strong++; }
void AIBinder_decStrong(AIBinder* b) { b->strong--; }
AIBinder_Weak* AIBinder_Weak_new(AIBinder* b) { return new AIBinder_Weak{b}; }
void AIBinder_Weak_delete(AIBinder_Weak* w) { delete w; }
AIBinder* AIBinder_Weak_promote(AIBinder_Weak* w) {
  if (!w || !w->b) return nullptr;
  w->b->strong++;
  return w->b;
}
void AIBinder_markVintfStability(AIBinder*) {}

static std::map<std::string, AIBinder*>& services() {
  static std::map<std::string, AIBinder*> s;
  return s;
}
binder_exception_t AServiceManager_addService(AIBinder* b, const char* instance) {
  fprintf(stderr, "FAKEBINDER addService %s\n", instance);
  services()[instance] = b;
  return EX_NONE;
}
bool ABinderProcess_setThreadPoolMaxThreadCount(uint32_t) { return true; }

AStatus* AStatus_newOk() { return new AStatus(); }
AStatus* AStatus_fromServiceSpecificError(int32_t e) { return new AStatus{EX_SERVICE_SPECIFIC, e, ""}; }
AStatus* AStatus_fromServiceSpecificErrorWithMessage(int32_t e, const char* m) {
  return new AStatus{EX_SERVICE_SPECIFIC, e, m ? m : ""};
}
bool AStatus_isOk(const AStatus* s) { return s->ex == EX_NONE; }
void AStatus_delete(AStatus* s) { delete s; }

int32_t AParcel_getDataPosition(const AParcel* p) { return (int32_t)p->pos; }
binder_status_t AParcel_setDataPosition(const AParcel* p, int32_t pos) {
  if (pos < 0) return STATUS_BAD_VALUE;
  const_cast<AParcel*>(p)->pos = (size_t)pos;
  return STATUS_OK;
}
binder_status_t AParcel_writeInt32(AParcel* p, int32_t v) { put(p, &v, 4); return STATUS_OK; }
binder_status_t AParcel_writeInt64(AParcel* p, int64_t v) { put(p, &v, 8); return STATUS_OK; }
binder_status_t AParcel_writeBool(AParcel* p, bool v) { return AParcel_writeInt32(p, v ? 1 : 0); }
binder_status_t AParcel_readInt32(const AParcel* p, int32_t* v) { return get(p, v, 4); }
binder_status_t AParcel_readInt64(const AParcel* p, int64_t* v) { return get(p, v, 8); }
binder_status_t AParcel_readBool(const AParcel* p, bool* v) {
  int32_t i;
  binder_status_t s = get(p, &i, 4);
  if (s == STATUS_OK) *v = i != 0;
  return s;
}
binder_status_t AParcel_writeByteArray(AParcel* p, const int8_t* a, int32_t n) {
  AParcel_writeInt32(p, n);
  if (a && n > 0) put(p, a, (size_t)n);
  return STATUS_OK;
}
typedef bool (*AParcel_byteArrayAllocator)(void* arrayData, int32_t length, int8_t** outBuffer);
binder_status_t AParcel_readByteArray(const AParcel* p, void* arrayData, AParcel_byteArrayAllocator alloc) {
  int32_t n;
  binder_status_t s = AParcel_readInt32(p, &n);
  if (s != STATUS_OK) return s;
  int8_t* buf = nullptr;
  if (!alloc(arrayData, n, &buf)) return STATUS_NO_MEMORY;
  if (n > 0) return get(p, buf, (size_t)n);
  return STATUS_OK;
}
binder_status_t AParcel_writeString(AParcel* p, const char* str, int32_t n) {
  AParcel_writeInt32(p, n);
  if (str && n > 0) put(p, str, (size_t)n);
  return STATUS_OK;
}
binder_status_t AParcel_writeStrongBinder(AParcel* p, AIBinder* b) {
  uint64_t v = (uint64_t)(uintptr_t)b;
  put(p, &v, 8);
  return STATUS_OK;
}
binder_status_t AParcel_writeStatusHeader(AParcel* p, const AStatus* s) {
  AParcel_writeInt32(p, s->ex);
  if (s->ex == EX_SERVICE_SPECIFIC) {
    AParcel_writeInt32(p, s->ss);
    AParcel_writeString(p, s->msg.c_str(), (int32_t)s->msg.size());
  }
  return STATUS_OK;
}
typedef bool (*AParcel_parcelableArrayAllocator)(void* arrayData, int32_t length);
typedef binder_status_t (*AParcel_readParcelableElement)(const AParcel* p, void* arrayData, size_t index);
typedef binder_status_t (*AParcel_writeParcelableElement)(AParcel* p, const void* arrayData, size_t index);
binder_status_t AParcel_readParcelableArray(const AParcel* p, void* arrayData,
                                            AParcel_parcelableArrayAllocator alloc,
                                            AParcel_readParcelableElement reader) {
  int32_t n;
  binder_status_t s = AParcel_readInt32(p, &n);
  if (s != STATUS_OK) return s;
  if (!alloc(arrayData, n)) return STATUS_NO_MEMORY;
  for (int32_t i = 0; i < n; i++) {
    s = reader(p, arrayData, (size_t)i);
    if (s != STATUS_OK) return s;
  }
  return STATUS_OK;
}
binder_status_t AParcel_writeParcelableArray(AParcel* p, const void* arrayData, int32_t n,
                                             AParcel_writeParcelableElement writer) {
  AParcel_writeInt32(p, n);
  for (int32_t i = 0; i < n; i++) {
    binder_status_t s = writer(p, arrayData, (size_t)i);
    if (s != STATUS_OK) return s;
  }
  return STATUS_OK;
}

// System property name and value
struct prop_info { const char* name; const char* value; };
static prop_info kProps[] = {
    {"ro.build.version.release", "16"},
    {"ro.build.version.security_patch", "2025-12-05"},
    {"ro.vendor.build.security_patch", "2025-12-05"},
    {"ro.boot.verifiedbootstate", "orange"},
    {"ro.boot.vbmeta.device_state", "unlocked"},
};
const prop_info* __system_property_find(const char* name) {
  for (auto& p : kProps)
    if (!strcmp(p.name, name)) return &p;
  return nullptr;
}
int __system_property_get(const char* name, char* value) {
  const prop_info* p = __system_property_find(name);
  if (!p) { value[0] = 0; return 0; }
  strcpy(value, p->value);
  return (int)strlen(p->value);
}
void __system_property_read_callback(const prop_info* pi,
                                     void (*cb)(void*, const char*, const char*, uint32_t),
                                     void* cookie) {
  cb(cookie, pi->name, pi->value, 1);
}
struct timespec;
bool __system_property_wait(const prop_info*, uint32_t, uint32_t*, const struct timespec*) {
  return false;
}

static const uint32_t FIRST = 1;

// send a transaction and return the reply
static AParcel call(const char* instance, uint32_t code, const char* what, AParcel in,
                    bool* ok) {
  AParcel out;
  *ok = false;
  auto it = services().find(instance);
  if (it == services().end()) {
    printf("FAKEBINDER %s: no service %s\n", what, instance);
    fflush(stdout);
    return out;
  }
  in.pos = 0;
  printf("FAKEBINDER call %s\n", what);
  fflush(stdout);
  binder_status_t st = it->second->clazz->onTransact(it->second, code, &in, &out);
  out.pos = 0;
  int32_t ex = -1;
  AParcel_readInt32(&out, &ex);
  int32_t ss = 0;
  if (ex == EX_SERVICE_SPECIFIC) AParcel_readInt32(&out, &ss);
  printf("FAKEBINDER reply %s: transact=%d exception=%d service_specific=%d\n", what, st, ex, ss);
  fflush(stdout);
  if (ex == EX_SERVICE_SPECIFIC) {
    int32_t n;
    AParcel_readInt32(&out, &n);
    if (n > 0) out.pos += (n + 3) & ~3;
  }
  *ok = st == STATUS_OK && ex == EX_NONE;
  return out;
}

// write a KeyParameter element to a parcel
static void keyParam(AParcel* p, int32_t tag, int32_t unionTag, int64_t v) {
  AParcel_writeInt32(p, 1);
  int32_t start = AParcel_getDataPosition(p);
  AParcel_writeInt32(p, 0);
  AParcel_writeInt32(p, tag);
  AParcel_writeInt32(p, 1);
  AParcel_writeInt32(p, unionTag);
  if (unionTag == 12 || unionTag == 13) AParcel_writeInt64(p, v);
  else AParcel_writeInt32(p, (int32_t)v);
  int32_t end = AParcel_getDataPosition(p);
  AParcel_setDataPosition(p, start);
  AParcel_writeInt32(p, end - start);
  AParcel_setDataPosition(p, end);
}

static const char* KM = "android.hardware.security.keymint.IKeyMintDevice/default";
static const char* SS = "android.hardware.security.sharedsecret.ISharedSecret/default";

// send the keystore2 boot calls to the services
void ABinderProcess_joinThreadPool() {
  bool ok;
  call(KM, FIRST + 16777214, "IKeyMintDevice.getInterfaceVersion", AParcel(), &ok);
  call(KM, FIRST + 0, "IKeyMintDevice.getHardwareInfo", AParcel(), &ok);
  AParcel params = call(SS, FIRST + 0, "ISharedSecret.getSharedSecretParameters", AParcel(), &ok);
  if (ok) {
    AParcel in;
    AParcel_writeInt32(&in, 1);
    in.d.insert(in.d.end(), params.d.begin() + params.pos, params.d.end());
    in.pos = in.d.size();
    call(SS, FIRST + 1, "ISharedSecret.computeSharedSecret", in, &ok);
  }
  call(KM, FIRST + 11, "IKeyMintDevice.earlyBootEnded", AParcel(), &ok);
  {
    AParcel in;
    AParcel_writeInt32(&in, 8);
    keyParam(&in, 0x20000001, 7, 0);
    keyParam(&in, 0x20000001, 7, 1);
    keyParam(&in, 0x10000002, 1, 32);
    keyParam(&in, 0x30000003, 11, 256);
    keyParam(&in, 0x20000004, 2, 32);
    keyParam(&in, 0x20000006, 3, 1);
    keyParam(&in, 0x30000008, 11, 128);
    keyParam(&in, 0x700001F7, 10, 1);
    AParcel_writeInt32(&in, 0);
    call(KM, FIRST + 2, "IKeyMintDevice.generateKey(AES)", in, &ok);
  }
  {
    AParcel in;
    AParcel_writeInt32(&in, 6);
    keyParam(&in, 0x20000001, 7, 2);
    keyParam(&in, 0x10000002, 1, 128);
    keyParam(&in, 0x30000003, 11, 256);
    keyParam(&in, 0x20000005, 4, 4);
    keyParam(&in, 0x30000008, 11, 256);
    keyParam(&in, 0x700001F7, 10, 1);
    AParcel_writeInt32(&in, 0);
    call(KM, FIRST + 2, "IKeyMintDevice.generateKey(HMAC)", in, &ok);
  }
  printf("FAKEBINDER done\n");
  fflush(stdout);
  _exit(0);
}

}
