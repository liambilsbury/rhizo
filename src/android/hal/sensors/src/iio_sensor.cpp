// poll an IIO sensor at its batch period on a thread
#include "iio_sensor.h"

#include <errno.h>
#include <poll.h>
#include <sched.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>

#include "log.h"

namespace rhizo::sensors {

namespace {

constexpr int64_t kDefaultPeriodNs = 200000000;
constexpr int64_t kOnChangePollFloorNs = 100000000;
constexpr int64_t kContinuousFloorNs = 1000000;

// set the lowest SCHED_FIFO priority
void setRealtime() {
  static std::atomic<bool> warned{false};
  sched_param p{};
  p.sched_priority = 1;
  if (sched_setscheduler(0, SCHED_FIFO, &p) != 0 && !warned.exchange(true)) {
    klogf("SCHED_FIFO refused (%s); polling at normal priority", strerror(errno));
  }
}

// arm the timer at an absolute CLOCK_BOOTTIME deadline
void armTimer(int fd, int64_t deadlineNs) {
  itimerspec its{};
  its.it_value.tv_sec = deadlineNs / 1000000000LL;
  its.it_value.tv_nsec = deadlineNs % 1000000000LL;
  if (deadlineNs > 0 && its.it_value.tv_sec == 0 && its.it_value.tv_nsec == 0) its.it_value.tv_nsec = 1;
  timerfd_settime(fd, deadlineNs > 0 ? TFD_TIMER_ABSTIME : 0, &its, nullptr);
}

}

// clamp a requested period to the sensor's delays
int64_t IioSensor::clampPeriodNs(const SensorConf& conf, int64_t requestedNs) {
  int64_t lo = static_cast<int64_t>(conf.minDelayUs) * 1000;
  if (lo <= 0) lo = conf.mode == Mode::OnChange ? kOnChangePollFloorNs : kContinuousFloorNs;
  int64_t hi = std::max(static_cast<int64_t>(conf.maxDelayUs) * 1000, lo);
  return std::min(std::max(requestedNs, lo), hi);
}

// return the clamped SENSOR_DELAY_NORMAL period
int64_t IioSensor::defaultPeriodNs(const SensorConf& conf) {
  return clampPeriodNs(conf, kDefaultPeriodNs);
}

IioSensor::IioSensor(const SensorConf& conf, std::string name, SampleSink* sink)
    : conf_(conf), name_(std::move(name)), sink_(sink), periodNs_(defaultPeriodNs(conf)) {
  wakeFd_ = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  timerFd_ = timerfd_create(CLOCK_BOOTTIME, TFD_CLOEXEC | TFD_NONBLOCK);
  if (wakeFd_ < 0 || timerFd_ < 0) {
    klogf("%s: no eventfd or CLOCK_BOOTTIME timerfd (%s); it will never report", name_.c_str(), strerror(errno));
    return;
  }
  thread_ = std::thread([this] { run(); });
}

IioSensor::~IioSensor() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    stop_ = true;
    wake();
  }
  if (thread_.joinable()) thread_.join();
  if (wakeFd_ >= 0) close(wakeFd_);
  if (timerFd_ >= 0) close(timerFd_);
}

// wake the poll thread
void IioSensor::wake() {
  uint64_t one = 1;
  if (wakeFd_ >= 0) (void)!write(wakeFd_, &one, sizeof(one));
}

// enable or disable sampling
void IioSensor::activate(bool enable) {
  std::lock_guard<std::mutex> lk(mu_);
  if (enabled_ == enable) return;
  enabled_ = enable;
  epoch_++;
  wake();
}

// disable and drop undelivered flushes
void IioSensor::reset() {
  std::lock_guard<std::mutex> lk(mu_);
  if (enabled_) epoch_++;
  enabled_ = false;
  pendingFlushes_ = 0;
  wake();
}

// set the sampling period from a batch request
void IioSensor::setPeriodNs(int64_t requestedNs) {
  std::lock_guard<std::mutex> lk(mu_);
  int64_t p = clampPeriodNs(conf_, requestedNs);
  if (p == periodNs_) return;
  periodNs_ = p;
  wake();
}

// queue a flush-complete when enabled
bool IioSensor::flush() {
  std::lock_guard<std::mutex> lk(mu_);
  if (!enabled_) return false;
  pendingFlushes_++;
  wake();
  return true;
}

bool IioSensor::enabled() const {
  std::lock_guard<std::mutex> lk(mu_);
  return enabled_;
}

// return the clamped sampling period
int64_t IioSensor::periodNs() const {
  std::lock_guard<std::mutex> lk(mu_);
  return periodNs_;
}

// return true while reads fail
bool IioSensor::paused() const {
  std::lock_guard<std::mutex> lk(mu_);
  return paused_;
}

// deliver the pending flush-completes
void IioSensor::emitFlushes() {
  std::lock_guard<std::mutex> lk(mu_);
  while (pendingFlushes_ > 0) {
    pendingFlushes_--;
    sink_->onFlushComplete();
  }
}

// read the channels and deliver a current reading
void IioSensor::sampleOnce(IioChannels& channels, ReadHealth& health, uint64_t epoch) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    if (!enabled_ || epoch_ != epoch || stop_) return;
  }
  Reading r;
  std::string failed;
  int err = channels.read(&r, &failed);
  health.note(err, failed);
  std::lock_guard<std::mutex> lk(mu_);
  paused_ = health.paused();
  if (err || !enabled_ || epoch_ != epoch || stop_) return;
  if (conf_.mode == Mode::OnChange && havePrev_ && r.v[0] == prev_) return;
  if (r.timestampNs <= lastTs_) r.timestampNs = lastTs_ + 1;
  lastTs_ = r.timestampNs;
  if (conf_.mode == Mode::OnChange) {
    prev_ = r.v[0];
    havePrev_ = true;
  }
  sink_->onReading(r);
}

// run the poll loop on the wake eventfd and the timerfd
void IioSensor::run() {
  setRealtime();
  IioChannels channels(conf_);
  ReadHealth health(name_);
  bool running = false;
  uint64_t curEpoch = 0;
  int64_t period = 0;
  int64_t lastTick = 0;
  int64_t deadline = 0;
  for (;;) {
    bool want;
    uint64_t epoch;
    int64_t newPeriod;
    {
      std::lock_guard<std::mutex> lk(mu_);
      if (stop_) break;
      want = enabled_;
      epoch = epoch_;
      newPeriod = periodNs_;
    }
    emitFlushes();
    if (running && (!want || epoch != curEpoch)) {
      channels.stop();
      running = false;
      armTimer(timerFd_, 0);
      std::lock_guard<std::mutex> lk(mu_);
      havePrev_ = false;
    }
    if (want && !running) {
      channels.start();
      running = true;
      curEpoch = epoch;
      period = newPeriod;
      lastTick = bootTimeNs();
      sampleOnce(channels, health, curEpoch);
      deadline = lastTick + period;
      armTimer(timerFd_, deadline);
    } else if (running && newPeriod != period) {
      period = newPeriod;
      deadline = std::max(lastTick + period, bootTimeNs());
      armTimer(timerFd_, deadline);
    }
    pollfd pfd[2] = {{wakeFd_, POLLIN, 0}, {timerFd_, POLLIN, 0}};
    if (poll(pfd, 2, -1) < 0) {
      if (errno == EINTR) continue;
      klogf("%s: poll failed (%s); it stops reporting", name_.c_str(), strerror(errno));
      break;
    }
    uint64_t count = 0;
    if (pfd[0].revents & POLLIN) (void)!read(wakeFd_, &count, sizeof(count));
    if (!(pfd[1].revents & POLLIN)) continue;
    (void)!read(timerFd_, &count, sizeof(count));
    if (!running) continue;
    lastTick = deadline;
    sampleOnce(channels, health, curEpoch);
    deadline += period;
    int64_t now = bootTimeNs();
    if (deadline <= now) {
      lastTick = now;
      deadline = now + period;
    }
    armTimer(timerFd_, deadline);
  }
  channels.stop();
}

}
