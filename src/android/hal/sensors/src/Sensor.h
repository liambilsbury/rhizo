/*
 * Copyright (C) 2021 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Modified for Rhizo.

#pragma once

#include <aidl/android/hardware/sensors/BnSensors.h>

#include <vector>

#include "conf.h"
#include "iio_sensor.h"

namespace aidl {
namespace android {
namespace hardware {
namespace sensors {

class ISensorsEventCallback {
  public:
    using Event = ::aidl::android::hardware::sensors::Event;

    virtual ~ISensorsEventCallback(){};
    virtual void postEvents(const std::vector<Event>& events) = 0;
};

class Sensor : public ::rhizo::sensors::SampleSink {
  public:
    using Event = ::aidl::android::hardware::sensors::Event;
    using EventPayload = ::aidl::android::hardware::sensors::Event::EventPayload;
    using SensorInfo = ::aidl::android::hardware::sensors::SensorInfo;
    using SensorType = ::aidl::android::hardware::sensors::SensorType;
    using MetaDataEventType =
            ::aidl::android::hardware::sensors::Event::EventPayload::MetaData::MetaDataEventType;

    Sensor(const ::rhizo::sensors::SensorConf& conf, const ::rhizo::sensors::ServedSensor& served,
           ISensorsEventCallback* callback);

    const SensorInfo& getSensorInfo() const;
    void batch(int64_t samplingPeriodNs);
    void activate(bool enable);
    void reset();
    ndk::ScopedAStatus flush();
    ndk::ScopedAStatus injectEvent(const Event& event);

    void onReading(const ::rhizo::sensors::Reading& reading) override;
    void onFlushComplete() override;

  private:
    SensorInfo mSensorInfo;
    ISensorsEventCallback* mCallback;
    bool mUncalibrated;
    ::rhizo::sensors::Kind mKind;
    // last: its poll thread calls back into the members above, and it is destroyed (joined) first
    ::rhizo::sensors::IioSensor mIio;
};

// the SensorInfo a conf entry is served as, built from the conf alone so it is identical on every start
SensorInfo makeSensorInfo(const ::rhizo::sensors::ServedSensor& served);

}  // namespace sensors
}  // namespace hardware
}  // namespace android
}  // namespace aidl
