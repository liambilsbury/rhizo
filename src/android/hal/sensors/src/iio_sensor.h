// poll an IIO sensor at its batch period on a thread
#ifndef RHIZO_SENSORS_IIO_SENSOR_H
#define RHIZO_SENSORS_IIO_SENSOR_H

#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

#include "conf.h"
#include "iio_reader.h"

namespace rhizo::sensors {

// receive readings and flush completions under the sensor lock
class SampleSink {
 public:
  virtual ~SampleSink() = default;
  virtual void onReading(const Reading& reading) = 0;
  virtual void onFlushComplete() = 0;
};

class IioSensor {
 public:
  IioSensor(const SensorConf& conf, std::string name, SampleSink* sink);
  ~IioSensor();
  IioSensor(const IioSensor&) = delete;
  IioSensor& operator=(const IioSensor&) = delete;

  void activate(bool enable);
  void reset();
  void setPeriodNs(int64_t requestedNs);
  bool flush();

  bool enabled() const;
  int64_t periodNs() const;
  bool paused() const;

  static int64_t clampPeriodNs(const SensorConf& conf, int64_t requestedNs);
  static int64_t defaultPeriodNs(const SensorConf& conf);

 private:
  void run();
  void wake();
  void emitFlushes();
  void sampleOnce(IioChannels& channels, ReadHealth& health, uint64_t epoch);

  const SensorConf& conf_;
  std::string name_;
  SampleSink* sink_;
  int wakeFd_ = -1;
  int timerFd_ = -1;

  mutable std::mutex mu_;
  bool enabled_ = false;
  bool stop_ = false;
  uint64_t epoch_ = 0;
  int64_t periodNs_ = 0;
  int pendingFlushes_ = 0;
  bool paused_ = false;

  bool havePrev_ = false;
  float prev_ = 0;
  int64_t lastTs_ = 0;

  std::thread thread_;
};

}

#endif
