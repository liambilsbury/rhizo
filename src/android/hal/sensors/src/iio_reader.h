// read a sensor's IIO channel files
#ifndef RHIZO_SENSORS_IIO_READER_H
#define RHIZO_SENSORS_IIO_READER_H

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "conf.h"

namespace rhizo::sensors {

struct Reading {
  int64_t timestampNs = 0;
  float v[3] = {0, 0, 0};
  int count = 0;
};

int64_t bootTimeNs();

bool parseIioValue(const char* text, size_t len, double* out);

class IioChannels {
 public:
  explicit IioChannels(const SensorConf& conf);
  ~IioChannels();
  IioChannels(const IioChannels&) = delete;
  IioChannels& operator=(const IioChannels&) = delete;

  void start();
  void stop();
  int read(Reading* out, std::string* failedPath);
  double scale(size_t i) const { return scale_[i]; }
  double offset(size_t i) const { return offset_[i]; }

 private:
  const SensorConf& conf_;
  std::vector<int> fds_;
  std::vector<double> scale_;
  std::vector<double> offset_;
};

// log each change between paused and resumed
class ReadHealth {
 public:
  explicit ReadHealth(std::string sensorName) : name_(std::move(sensorName)) {}
  void note(int err, const std::string& failedPath);
  bool paused() const { return paused_; }

 private:
  std::string name_;
  bool paused_ = false;
};

}

#endif
