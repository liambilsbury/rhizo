// parse /vendor/etc/rhizo-sensors.conf
#ifndef RHIZO_SENSORS_CONF_H
#define RHIZO_SENSORS_CONF_H

#include <cstdint>
#include <string>
#include <vector>

namespace rhizo::sensors {

enum class Kind { Accelerometer, Gyroscope, Magnetometer, Light };
enum class Mode { Continuous, OnChange };

struct ChannelConf {
  std::string path;
  double scale = 0;
  double offset = 0;
  std::string scalePath;
  std::string offsetPath;
};

struct SensorConf {
  int32_t handle = 0;
  Kind kind = Kind::Accelerometer;
  std::string name;
  std::string vendor;
  std::string device;
  std::vector<ChannelConf> channels;
  double matrix[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
  float range = 0;
  float resolution = 0;
  float power = 0;
  int32_t minDelayUs = 0;
  int32_t maxDelayUs = 0;
  Mode mode = Mode::Continuous;
};

struct Conf {
  std::vector<SensorConf> sensors;
};

// a conf parse error and its line
struct ConfError {
  std::string code;
  int line = 0;
  std::string detail;
};

constexpr int32_t kTypeAccelerometer = 1;
constexpr int32_t kTypeMagneticField = 2;
constexpr int32_t kTypeGyroscope = 4;
constexpr int32_t kTypeLight = 5;
constexpr int32_t kTypeMagneticFieldUncalibrated = 14;
constexpr int32_t kFlagContinuous = 0;
constexpr int32_t kFlagOnChange = 2;

// a conf sensor or a magnetometer's uncalibrated twin
struct ServedSensor {
  size_t confIndex = 0;
  bool uncalibrated = false;
  int32_t handle = 0;
  std::string name;
  std::string vendor;
  int32_t version = 1;
  int32_t type = 0;
  float maxRange = 0;
  float resolution = 0;
  float power = 0;
  int32_t minDelayUs = 0;
  int32_t maxDelayUs = 0;
  int32_t fifoReservedEventCount = 0;
  int32_t fifoMaxEventCount = 0;
  int32_t flags = 0;
};

constexpr const char* kConfPath = "/vendor/etc/rhizo-sensors.conf";
constexpr const char* kChannelRoot = "/dev/rhizo_iio/";
constexpr size_t kMaxSensors = 32;

bool parseConf(const std::string& text, Conf* out, ConfError* err, const std::string& channelRoot = kChannelRoot);

bool loadConf(const std::string& path, Conf* out, ConfError* err, const std::string& channelRoot = kChannelRoot);

std::vector<ServedSensor> servedSensors(const Conf& conf);

const char* kindName(Kind kind);

bool isVector(Kind kind);

double unitFactor(Kind kind);

}

#endif
