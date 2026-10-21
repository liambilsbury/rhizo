#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace rhizo_gnss_sim {

inline constexpr double kPi = 3.14159265358979323846;
inline constexpr double kL1Hz = 1575.42e6;
inline constexpr double kSpeedOfLight = 299792458.0;
inline constexpr double kGpsToUnixSeconds = 315964800.0;
inline constexpr int kGpsLeapSeconds = 18;
inline constexpr double kTrackedMinElevationDeg = 5.0;
inline constexpr double kUsedInFixMinElevationDeg = 10.0;
inline constexpr int64_t kDefaultSvIntervalMs = 1000;
inline constexpr int64_t kMinMeasurementIntervalMs = 1000;
inline constexpr int64_t kMinPositionIntervalMs = 100;

// satellite seen from a fix
struct Sat {
  int svid;
  double azimuthDeg;
  double elevationDeg;
  double cn0DbHz;
  double rangeM;
  double rangeRateMps;
  bool usedInFix;
};

// return the GPS time of week in seconds
inline double gpsTimeOfWeekSeconds(double unixSeconds) {
  double gps = unixSeconds - kGpsToUnixSeconds + kGpsLeapSeconds;
  return std::fmod(gps, 7.0 * 86400.0);
}

// point in ECEF meters
struct Vec {
  double x, y, z;
};

// return the ECEF position of a constellation slot
inline Vec slotEcef(int k, double gpsSeconds) {
  const double mu = 3.986005e14;
  const double a = 26559700.0;
  const double wE = 7.2921151467e-5;
  const double n = std::sqrt(mu / (a * a * a));
  const double inc = 55.0 * kPi / 180.0;
  int plane = k / 5, slot = k % 5;
  double raan = plane * 60.0 * kPi / 180.0;
  double u = std::fmod((slot * 72.0 + plane * 12.0) * kPi / 180.0 + n * gpsSeconds, 2.0 * kPi);
  double xo = a * std::cos(u), yo = a * std::sin(u);
  double xi = xo * std::cos(raan) - yo * std::cos(inc) * std::sin(raan);
  double yi = xo * std::sin(raan) + yo * std::cos(inc) * std::cos(raan);
  double zi = yo * std::sin(inc);
  double th = std::fmod(wE * gpsSeconds, 2.0 * kPi);
  return {xi * std::cos(th) + yi * std::sin(th), -xi * std::sin(th) + yi * std::cos(th), zi};
}

// return the ECEF position of a surface point
inline Vec observerEcef(double latDeg, double lonDeg) {
  const double a = 6378137.0, e2 = 6.69437999014e-3;
  double phi = latDeg * kPi / 180.0, lam = lonDeg * kPi / 180.0;
  double nn = a / std::sqrt(1.0 - e2 * std::sin(phi) * std::sin(phi));
  return {nn * std::cos(phi) * std::cos(lam), nn * std::cos(phi) * std::sin(lam),
          nn * (1.0 - e2) * std::sin(phi)};
}

// return the satellites tracked from a fix
inline std::vector<Sat> visible(double latDeg, double lonDeg, double gpsSeconds) {
  Vec o = observerEcef(latDeg, lonDeg);
  double phi = latDeg * kPi / 180.0, lam = lonDeg * kPi / 180.0;
  Vec east{-std::sin(lam), std::cos(lam), 0.0};
  Vec north{-std::sin(phi) * std::cos(lam), -std::sin(phi) * std::sin(lam), std::cos(phi)};
  Vec up{std::cos(phi) * std::cos(lam), std::cos(phi) * std::sin(lam), std::sin(phi)};
  std::vector<Sat> out;
  for (int k = 0; k < 30; k++) {
    Vec s = slotEcef(k, gpsSeconds);
    Vec d{s.x - o.x, s.y - o.y, s.z - o.z};
    double r = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    double e = d.x * east.x + d.y * east.y;
    double nn = d.x * north.x + d.y * north.y + d.z * north.z;
    double u = d.x * up.x + d.y * up.y + d.z * up.z;
    double el = std::asin(u / r) * 180.0 / kPi;
    if (el < kTrackedMinElevationDeg) continue;
    double az = std::fmod(std::atan2(e, nn) * 180.0 / kPi + 360.0, 360.0);
    Vec s1 = slotEcef(k, gpsSeconds + 1.0);
    double dx = s1.x - o.x, dy = s1.y - o.y, dz = s1.z - o.z;
    double r1 = std::sqrt(dx * dx + dy * dy + dz * dz);
    Sat sat;
    sat.svid = k + 1;
    sat.azimuthDeg = az;
    sat.elevationDeg = el;
    sat.cn0DbHz = 30.0 + 15.0 * std::sin(el * kPi / 180.0);
    sat.rangeM = r;
    sat.rangeRateMps = r1 - r;
    sat.usedInFix = el >= kUsedInFixMinElevationDeg;
    out.push_back(sat);
  }
  return out;
}

// active report streams and their intervals
struct Request {
  bool locationActive;
  int64_t locationMs;
  bool measurementActive;
  int64_t measurementMs;
};

// return the time between measurement reports
inline int64_t measurementIntervalMs(const Request& r) {
  int64_t m = std::max(r.measurementMs, kMinMeasurementIntervalMs);
  return r.locationActive ? std::min(r.locationMs, m) : m;
}

// return the time between satellite status reports
inline int64_t svStatusIntervalMs(const Request& r) {
  if (r.locationActive && r.measurementActive)
    return std::min(r.locationMs, measurementIntervalMs(r));
  if (r.locationActive) return r.locationMs;
  if (r.measurementActive) return measurementIntervalMs(r);
  return kDefaultSvIntervalMs;
}

}
