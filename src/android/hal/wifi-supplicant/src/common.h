#pragma once
#include "aidl/android/hardware/wifi/supplicant/BnSupplicant.h"
#include "aidl/android/hardware/wifi/supplicant/BnSupplicantStaIface.h"
#include "aidl/android/hardware/wifi/supplicant/BnSupplicantStaNetwork.h"
#include "aidl/android/hardware/wifi/supplicant/SupplicantStatusCode.h"
#include "rhizo/device_state.h"
#include <array>
#include <cstdio>
#include <string>
#include <vector>

namespace rhizo_supplicant {

using namespace aidl::android::hardware::wifi::supplicant;
using aidl::android::hardware::wifi::common::OuiKeyedData;
using ndk::ScopedAStatus;

// write a message to the kernel log
inline void klog(const char* msg) { rhizo_device::Klog("rhizo-wifi-supplicant", msg); }

// write a formatted message to the kernel log
template <typename... Args>
void klogf(const char* fmt, Args... args) {
  char buf[256];
  snprintf(buf, sizeof(buf), fmt, args...);
  klog(buf);
}

// return a service-specific SupplicantStatusCode failure
inline ScopedAStatus Status(SupplicantStatusCode code) {
  return ScopedAStatus::fromServiceSpecificError(static_cast<int32_t>(code));
}

// return an enum's backing value
template <typename E>
constexpr int32_t Bits(E e) {
  return static_cast<int32_t>(e);
}

// stored network configuration
struct NetworkConfig {
  std::vector<uint8_t> ssid;
  std::vector<uint8_t> bssid = std::vector<uint8_t>(6, 0);
  bool scan_ssid = false;
  bool require_pmf = false;
  KeyMgmtMask key_mgmt = KeyMgmtMask(Bits(KeyMgmtMask::WPA_PSK) | Bits(KeyMgmtMask::WPA_EAP));
  ProtoMask proto = ProtoMask(Bits(ProtoMask::WPA) | Bits(ProtoMask::RSN));
  AuthAlgMask auth_alg = AuthAlgMask(0);
  GroupCipherMask group_cipher = GroupCipherMask(Bits(GroupCipherMask::CCMP) | Bits(GroupCipherMask::TKIP) |
                                                 Bits(GroupCipherMask::WEP40) | Bits(GroupCipherMask::WEP104));
  PairwiseCipherMask pairwise_cipher =
      PairwiseCipherMask(Bits(PairwiseCipherMask::CCMP) | Bits(PairwiseCipherMask::TKIP));
  GroupMgmtCipherMask group_mgmt_cipher = GroupMgmtCipherMask(0);
  std::vector<uint8_t> psk;
  std::string psk_passphrase;
  std::string sae_password;
  std::string sae_password_id;
  SaeH2eMode sae_h2e = SaeH2eMode::DISABLED;
  std::array<std::vector<uint8_t>, 4> wep_keys;
  int32_t wep_tx_key_idx = 0;
  std::string id_str;
  EapMethod eap_method = EapMethod::PEAP;
  EapPhase2Method eap_phase2 = EapPhase2Method::NONE;
  std::vector<uint8_t> eap_identity;
  std::vector<uint8_t> eap_anonymous_identity;
  std::vector<uint8_t> eap_encrypted_imsi_identity;
  std::vector<uint8_t> eap_password;
  std::string eap_ca_cert;
  std::string eap_ca_path;
  std::string eap_client_cert;
  std::string eap_private_key_id;
  std::string eap_subject_match;
  std::string eap_alt_subject_match;
  std::string eap_domain_suffix_match;
  std::string eap_engine_id;
  bool eap_engine = false;
  bool eap_erp = false;
  OcspType ocsp = OcspType::NONE;
  TlsVersion min_tls = TlsVersion::TLS_V1_0;
  std::string wapi_cert_suite;
  bool edmg = false;
  bool proactive_key_caching = false;
  bool strict_conservative_peer = false;
  bool suite_b_openssl_ciphers = false;
  bool tls_suite_b_phase1 = false;
  bool eht_disabled = false;
  int32_t update_identifier = 0;
  std::vector<uint8_t> roaming_consortium_selection;
  DppConnectionKeys dpp_keys;
  std::vector<OuiKeyedData> vendor_data;
  bool enabled = false;

  // return true when the configuration can join an open BSS
  bool Open() const {
    if (!(Bits(key_mgmt) & Bits(KeyMgmtMask::NONE))) return false;
    for (auto& k : wep_keys) {
      if (!k.empty()) return false;
    }
    return true;
  }
  // return true when a BSSID constraint is set
  bool PinsBssid() const {
    for (uint8_t b : bssid) {
      if (b) return true;
    }
    return false;
  }
};

}
