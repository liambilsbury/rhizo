#pragma once
#include "common.h"
#include "rhizo/wifi_callbacks.h"
#include <atomic>
#include <memory>
#include <mutex>

namespace rhizo_supplicant {

class StaIface;

// stored network joined on select()
class StaNetwork : public BnSupplicantStaNetwork {
 public:
  StaNetwork(std::weak_ptr<StaIface> iface, int32_t id, std::string ifname)
      : iface_(std::move(iface)), id_(id), ifname_(std::move(ifname)) {}

  // drop this network from service
  void Invalidate() {
    valid_ = false;
    callbacks_.Clear();
  }
  // return a copy of the configuration
  NetworkConfig Config() const {
    std::lock_guard<std::mutex> lg(mu_);
    return cfg_;
  }
  // mark the network enabled or disabled
  void SetEnabled(bool on) {
    std::lock_guard<std::mutex> lg(mu_);
    cfg_.enabled = on;
  }
  int32_t id() const { return id_; }

  ScopedAStatus select() override;
  ScopedAStatus enable(bool no_connect) override;
  ScopedAStatus disable() override;

  ScopedAStatus getId(int32_t* out) override { return Get([&] { *out = id_; }); }
  ScopedAStatus getInterfaceName(std::string* out) override { return Get([&] { *out = ifname_; }); }
  ScopedAStatus getType(IfaceType* out) override { return Get([&] { *out = IfaceType::STA; }); }
  ScopedAStatus registerCallback(const std::shared_ptr<ISupplicantStaNetworkCallback>& cb) override {
    if (!valid_) return Invalid();
    if (!cb) return Status(SupplicantStatusCode::FAILURE_ARGS_INVALID);
    callbacks_.Add(cb);
    return ScopedAStatus::ok();
  }

  ScopedAStatus setSsid(const std::vector<uint8_t>& v) override {
    if (v.empty() || v.size() > size_t(SSID_MAX_LEN_IN_BYTES)) return Args();
    return Set([&] { cfg_.ssid = v; });
  }
  ScopedAStatus getSsid(std::vector<uint8_t>* out) override { return Get([&] { *out = cfg_.ssid; }); }
  ScopedAStatus setBssid(const std::vector<uint8_t>& v) override {
    if (v.size() != 6) return Args();
    return Set([&] { cfg_.bssid = v; });
  }
  ScopedAStatus getBssid(std::vector<uint8_t>* out) override { return Get([&] { *out = cfg_.bssid; }); }
  ScopedAStatus setScanSsid(bool v) override { return Set([&] { cfg_.scan_ssid = v; }); }
  ScopedAStatus getScanSsid(bool* out) override { return Get([&] { *out = cfg_.scan_ssid; }); }
  ScopedAStatus setRequirePmf(bool v) override { return Set([&] { cfg_.require_pmf = v; }); }
  ScopedAStatus getRequirePmf(bool* out) override { return Get([&] { *out = cfg_.require_pmf; }); }
  ScopedAStatus setKeyMgmt(KeyMgmtMask v) override { return Set([&] { cfg_.key_mgmt = v; }); }
  ScopedAStatus getKeyMgmt(KeyMgmtMask* out) override { return Get([&] { *out = cfg_.key_mgmt; }); }
  ScopedAStatus setProto(ProtoMask v) override { return Set([&] { cfg_.proto = v; }); }
  ScopedAStatus getProto(ProtoMask* out) override { return Get([&] { *out = cfg_.proto; }); }
  ScopedAStatus setAuthAlg(AuthAlgMask v) override { return Set([&] { cfg_.auth_alg = v; }); }
  ScopedAStatus getAuthAlg(AuthAlgMask* out) override { return Get([&] { *out = cfg_.auth_alg; }); }
  ScopedAStatus setGroupCipher(GroupCipherMask v) override { return Set([&] { cfg_.group_cipher = v; }); }
  ScopedAStatus getGroupCipher(GroupCipherMask* out) override { return Get([&] { *out = cfg_.group_cipher; }); }
  ScopedAStatus setPairwiseCipher(PairwiseCipherMask v) override { return Set([&] { cfg_.pairwise_cipher = v; }); }
  ScopedAStatus getPairwiseCipher(PairwiseCipherMask* out) override {
    return Get([&] { *out = cfg_.pairwise_cipher; });
  }
  ScopedAStatus setGroupMgmtCipher(GroupMgmtCipherMask v) override {
    return Set([&] { cfg_.group_mgmt_cipher = v; });
  }
  ScopedAStatus getGroupMgmtCipher(GroupMgmtCipherMask* out) override {
    return Get([&] { *out = cfg_.group_mgmt_cipher; });
  }
  ScopedAStatus setPsk(const std::vector<uint8_t>& v) override {
    if (v.size() != 32) return Args();
    return Set([&] { cfg_.psk = v; });
  }
  ScopedAStatus getPsk(std::vector<uint8_t>* out) override { return Get([&] { *out = cfg_.psk; }); }
  ScopedAStatus setPskPassphrase(const std::string& v) override {
    if (v.size() < size_t(PSK_PASSPHRASE_MIN_LEN_IN_BYTES) || v.size() > size_t(PSK_PASSPHRASE_MAX_LEN_IN_BYTES))
      return Args();
    return Set([&] { cfg_.psk_passphrase = v; });
  }
  ScopedAStatus getPskPassphrase(std::string* out) override { return Get([&] { *out = cfg_.psk_passphrase; }); }
  ScopedAStatus setSaePassword(const std::string& v) override { return Set([&] { cfg_.sae_password = v; }); }
  ScopedAStatus getSaePassword(std::string* out) override { return Get([&] { *out = cfg_.sae_password; }); }
  ScopedAStatus setSaePasswordId(const std::string& v) override { return Set([&] { cfg_.sae_password_id = v; }); }
  ScopedAStatus getSaePasswordId(std::string* out) override { return Get([&] { *out = cfg_.sae_password_id; }); }
  ScopedAStatus setSaeH2eMode(SaeH2eMode v) override { return Set([&] { cfg_.sae_h2e = v; }); }
  ScopedAStatus setWepKey(int32_t idx, const std::vector<uint8_t>& v) override {
    if (idx < 0 || idx >= WEP_KEYS_MAX_NUM) return Args();
    if (v.size() != size_t(WEP40_KEY_LEN_IN_BYTES) && v.size() != size_t(WEP104_KEY_LEN_IN_BYTES)) return Args();
    return Set([&] { cfg_.wep_keys[idx] = v; });
  }
  ScopedAStatus getWepKey(int32_t idx, std::vector<uint8_t>* out) override {
    if (idx < 0 || idx >= WEP_KEYS_MAX_NUM) return Args();
    return Get([&] { *out = cfg_.wep_keys[idx]; });
  }
  ScopedAStatus setWepTxKeyIdx(int32_t idx) override {
    if (idx < 0 || idx >= WEP_KEYS_MAX_NUM) return Args();
    return Set([&] { cfg_.wep_tx_key_idx = idx; });
  }
  ScopedAStatus getWepTxKeyIdx(int32_t* out) override { return Get([&] { *out = cfg_.wep_tx_key_idx; }); }
  ScopedAStatus setIdStr(const std::string& v) override { return Set([&] { cfg_.id_str = v; }); }
  ScopedAStatus getIdStr(std::string* out) override { return Get([&] { *out = cfg_.id_str; }); }

  ScopedAStatus setEapMethod(EapMethod v) override { return Set([&] { cfg_.eap_method = v; }); }
  ScopedAStatus getEapMethod(EapMethod* out) override { return Get([&] { *out = cfg_.eap_method; }); }
  ScopedAStatus setEapPhase2Method(EapPhase2Method v) override { return Set([&] { cfg_.eap_phase2 = v; }); }
  ScopedAStatus getEapPhase2Method(EapPhase2Method* out) override { return Get([&] { *out = cfg_.eap_phase2; }); }
  ScopedAStatus setEapIdentity(const std::vector<uint8_t>& v) override { return Set([&] { cfg_.eap_identity = v; }); }
  ScopedAStatus getEapIdentity(std::vector<uint8_t>* out) override { return Get([&] { *out = cfg_.eap_identity; }); }
  ScopedAStatus setEapAnonymousIdentity(const std::vector<uint8_t>& v) override {
    return Set([&] { cfg_.eap_anonymous_identity = v; });
  }
  ScopedAStatus getEapAnonymousIdentity(std::vector<uint8_t>* out) override {
    return Get([&] { *out = cfg_.eap_anonymous_identity; });
  }
  ScopedAStatus setEapEncryptedImsiIdentity(const std::vector<uint8_t>& v) override {
    return Set([&] { cfg_.eap_encrypted_imsi_identity = v; });
  }
  ScopedAStatus setEapPassword(const std::vector<uint8_t>& v) override { return Set([&] { cfg_.eap_password = v; }); }
  ScopedAStatus getEapPassword(std::vector<uint8_t>* out) override { return Get([&] { *out = cfg_.eap_password; }); }
  ScopedAStatus setEapCACert(const std::string& v) override { return Set([&] { cfg_.eap_ca_cert = v; }); }
  ScopedAStatus getEapCACert(std::string* out) override { return Get([&] { *out = cfg_.eap_ca_cert; }); }
  ScopedAStatus setEapCAPath(const std::string& v) override { return Set([&] { cfg_.eap_ca_path = v; }); }
  ScopedAStatus getEapCAPath(std::string* out) override { return Get([&] { *out = cfg_.eap_ca_path; }); }
  ScopedAStatus setEapClientCert(const std::string& v) override { return Set([&] { cfg_.eap_client_cert = v; }); }
  ScopedAStatus getEapClientCert(std::string* out) override { return Get([&] { *out = cfg_.eap_client_cert; }); }
  ScopedAStatus setEapPrivateKeyId(const std::string& v) override { return Set([&] { cfg_.eap_private_key_id = v; }); }
  ScopedAStatus getEapPrivateKeyId(std::string* out) override {
    return Get([&] { *out = cfg_.eap_private_key_id; });
  }
  ScopedAStatus setEapSubjectMatch(const std::string& v) override { return Set([&] { cfg_.eap_subject_match = v; }); }
  ScopedAStatus getEapSubjectMatch(std::string* out) override { return Get([&] { *out = cfg_.eap_subject_match; }); }
  ScopedAStatus setEapAltSubjectMatch(const std::string& v) override {
    return Set([&] { cfg_.eap_alt_subject_match = v; });
  }
  ScopedAStatus getEapAltSubjectMatch(std::string* out) override {
    return Get([&] { *out = cfg_.eap_alt_subject_match; });
  }
  ScopedAStatus setEapDomainSuffixMatch(const std::string& v) override {
    return Set([&] { cfg_.eap_domain_suffix_match = v; });
  }
  ScopedAStatus getEapDomainSuffixMatch(std::string* out) override {
    return Get([&] { *out = cfg_.eap_domain_suffix_match; });
  }
  ScopedAStatus setEapEngine(bool v) override { return Set([&] { cfg_.eap_engine = v; }); }
  ScopedAStatus getEapEngine(bool* out) override { return Get([&] { *out = cfg_.eap_engine; }); }
  ScopedAStatus setEapEngineID(const std::string& v) override { return Set([&] { cfg_.eap_engine_id = v; }); }
  ScopedAStatus getEapEngineId(std::string* out) override { return Get([&] { *out = cfg_.eap_engine_id; }); }
  ScopedAStatus setEapErp(bool v) override { return Set([&] { cfg_.eap_erp = v; }); }
  ScopedAStatus setOcsp(OcspType v) override {
    if (Bits(v) < Bits(OcspType::NONE) || Bits(v) > Bits(OcspType::REQUIRE_ALL_CERTS_STATUS)) return Args();
    return Set([&] { cfg_.ocsp = v; });
  }
  ScopedAStatus getOcsp(OcspType* out) override { return Get([&] { *out = cfg_.ocsp; }); }
  ScopedAStatus setMinimumTlsVersionEapPhase1Param(TlsVersion v) override {
    if (!valid_) return Invalid();
    if (Bits(v) < Bits(TlsVersion::TLS_V1_0) || Bits(v) > Bits(TlsVersion::TLS_V1_3)) return Args();
    if (v == TlsVersion::TLS_V1_3) return Status(SupplicantStatusCode::FAILURE_UNSUPPORTED);
    return Set([&] { cfg_.min_tls = v; });
  }
  ScopedAStatus enableSuiteBEapOpenSslCiphers() override { return Set([&] { cfg_.suite_b_openssl_ciphers = true; }); }
  ScopedAStatus enableTlsSuiteBEapPhase1Param(bool v) override { return Set([&] { cfg_.tls_suite_b_phase1 = v; }); }
  ScopedAStatus setWapiCertSuite(const std::string& v) override { return Set([&] { cfg_.wapi_cert_suite = v; }); }
  ScopedAStatus getWapiCertSuite(std::string* out) override { return Get([&] { *out = cfg_.wapi_cert_suite; }); }
  ScopedAStatus setEdmg(bool v) override { return Set([&] { cfg_.edmg = v; }); }
  ScopedAStatus getEdmg(bool* out) override { return Get([&] { *out = cfg_.edmg; }); }
  ScopedAStatus setProactiveKeyCaching(bool v) override { return Set([&] { cfg_.proactive_key_caching = v; }); }
  ScopedAStatus setStrictConservativePeerMode(bool v) override {
    return Set([&] { cfg_.strict_conservative_peer = v; });
  }
  ScopedAStatus setUpdateIdentifier(int32_t v) override { return Set([&] { cfg_.update_identifier = v; }); }
  ScopedAStatus setRoamingConsortiumSelection(const std::vector<uint8_t>& v) override {
    return Set([&] { cfg_.roaming_consortium_selection = v; });
  }
  ScopedAStatus setDppKeys(const DppConnectionKeys& v) override { return Set([&] { cfg_.dpp_keys = v; }); }
  ScopedAStatus disableEht() override { return Set([&] { cfg_.eht_disabled = true; }); }
  ScopedAStatus setVendorData(const std::vector<OuiKeyedData>& v) override { return Set([&] { cfg_.vendor_data = v; }); }

  ScopedAStatus enableSaePkOnlyMode(bool) override { return Unsupported(); }
  ScopedAStatus setPmkCache(const std::vector<uint8_t>&) override { return Unsupported(); }
  ScopedAStatus getWpsNfcConfigurationToken(std::vector<uint8_t>*) override { return Unsupported(); }
  ScopedAStatus sendNetworkEapIdentityResponse(const std::vector<uint8_t>&, const std::vector<uint8_t>&) override {
    return Unsupported();
  }
  ScopedAStatus sendNetworkEapSimGsmAuthFailure() override { return Unsupported(); }
  ScopedAStatus sendNetworkEapSimGsmAuthResponse(const std::vector<NetworkResponseEapSimGsmAuthParams>&) override {
    return Unsupported();
  }
  ScopedAStatus sendNetworkEapSimUmtsAuthFailure() override { return Unsupported(); }
  ScopedAStatus sendNetworkEapSimUmtsAuthResponse(const NetworkResponseEapSimUmtsAuthParams&) override {
    return Unsupported();
  }
  ScopedAStatus sendNetworkEapSimUmtsAutsResponse(const std::vector<uint8_t>&) override { return Unsupported(); }

 private:
  ScopedAStatus Invalid() const { return Status(SupplicantStatusCode::FAILURE_NETWORK_INVALID); }
  ScopedAStatus Args() const {
    return valid_ ? Status(SupplicantStatusCode::FAILURE_ARGS_INVALID) : Invalid();
  }
  ScopedAStatus Unsupported() const {
    return valid_ ? Status(SupplicantStatusCode::FAILURE_UNSUPPORTED) : Invalid();
  }
  // store a value under the lock
  template <typename F>
  ScopedAStatus Set(F f) {
    if (!valid_) return Invalid();
    std::lock_guard<std::mutex> lg(mu_);
    f();
    return ScopedAStatus::ok();
  }
  // read a value under the lock
  template <typename F>
  ScopedAStatus Get(F f) const {
    if (!valid_) return Invalid();
    std::lock_guard<std::mutex> lg(mu_);
    f();
    return ScopedAStatus::ok();
  }

  mutable std::mutex mu_;
  NetworkConfig cfg_;
  std::atomic<bool> valid_{true};
  std::weak_ptr<StaIface> iface_;
  const int32_t id_;
  const std::string ifname_;
  rhizo_wifi::CallbackList<ISupplicantStaNetworkCallback> callbacks_;
};

}
