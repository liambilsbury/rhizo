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

#include "Sensor.h"

using ::ndk::ScopedAStatus;

namespace aidl {
namespace android {
namespace hardware {
namespace sensors {

// the conf code computes SensorInfo's numbers without the AIDL headers; they must be the frozen V3's
static_assert(static_cast<int32_t>(SensorType::ACCELEROMETER) == ::rhizo::sensors::kTypeAccelerometer);
static_assert(static_cast<int32_t>(SensorType::MAGNETIC_FIELD) == ::rhizo::sensors::kTypeMagneticField);
static_assert(static_cast<int32_t>(SensorType::GYROSCOPE) == ::rhizo::sensors::kTypeGyroscope);
static_assert(static_cast<int32_t>(SensorType::LIGHT) == ::rhizo::sensors::kTypeLight);
static_assert(static_cast<int32_t>(SensorType::MAGNETIC_FIELD_UNCALIBRATED) ==
              ::rhizo::sensors::kTypeMagneticFieldUncalibrated);
static_assert(SensorInfo::SENSOR_FLAG_BITS_CONTINUOUS_MODE == ::rhizo::sensors::kFlagContinuous);
static_assert(SensorInfo::SENSOR_FLAG_BITS_ON_CHANGE_MODE == ::rhizo::sensors::kFlagOnChange);

// the SensorInfo a conf entry is served as, built from the conf alone so it is identical on every start
SensorInfo makeSensorInfo(const ::rhizo::sensors::ServedSensor& served) {
    SensorInfo info;
    info.sensorHandle = served.handle;
    info.name = served.name;
    info.vendor = served.vendor;
    info.version = served.version;
    info.type = static_cast<SensorType>(served.type);
    info.typeAsString = "";
    info.maxRange = served.maxRange;
    info.resolution = served.resolution;
    info.power = served.power;
    info.minDelayUs = served.minDelayUs;
    info.maxDelayUs = served.maxDelayUs;
    info.fifoReservedEventCount = served.fifoReservedEventCount;
    info.fifoMaxEventCount = served.fifoMaxEventCount;
    info.requiredPermission = "";
    info.flags = served.flags;
    return info;
}

Sensor::Sensor(const ::rhizo::sensors::SensorConf& conf, const ::rhizo::sensors::ServedSensor& served,
               ISensorsEventCallback* callback)
    : mSensorInfo(makeSensorInfo(served)),
      mCallback(callback),
      mUncalibrated(served.uncalibrated),
      mKind(conf.kind),
      mIio(conf, served.name, this) {}

const SensorInfo& Sensor::getSensorInfo() const {
    return mSensorInfo;
}

void Sensor::batch(int64_t samplingPeriodNs) {
    // clamped to [minDelayUs, maxDelayUs]: VTS passes the delays as nanoseconds, so a clamp, never a refusal
    mIio.setPeriodNs(samplingPeriodNs);
}

void Sensor::activate(bool enable) {
    mIio.activate(enable);
}

void Sensor::reset() {
    mIio.reset();
}

ScopedAStatus Sensor::flush() {
    // Only generate a flush complete event if the sensor is enabled (no sensor here is one-shot). There is no
    // FIFO, so the flush-complete follows the last reading this sensor's poll thread delivered.
    if (!mIio.flush()) {
        return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
    return ScopedAStatus::ok();
}

void Sensor::onFlushComplete() {
    Event ev;
    ev.sensorHandle = mSensorInfo.sensorHandle;
    ev.sensorType = SensorType::META_DATA;
    EventPayload::MetaData meta = {
            .what = MetaDataEventType::META_DATA_FLUSH_COMPLETE,
    };
    ev.payload.set<EventPayload::Tag::meta>(meta);
    std::vector<Event> evs{ev};
    mCallback->postEvents(evs);
}

void Sensor::onReading(const ::rhizo::sensors::Reading& reading) {
    Event event;
    event.sensorHandle = mSensorInfo.sensorHandle;
    event.sensorType = mSensorInfo.type;
    event.timestamp = reading.timestampNs;
    if (mKind == ::rhizo::sensors::Kind::Light) {
        event.payload.set<EventPayload::Tag::scalar>(reading.v[0]);
    } else if (mUncalibrated) {
        // no calibration is applied, so the bias is truthfully zero
        EventPayload::Uncal uncal = {
                .x = reading.v[0], .y = reading.v[1], .z = reading.v[2], .xBias = 0, .yBias = 0, .zBias = 0};
        event.payload.set<EventPayload::Tag::uncal>(uncal);
    } else {
        // the magnetometer is uncalibrated (no hard- or soft-iron correction), and says so
        EventPayload::Vec3 vec3 = {
                .x = reading.v[0],
                .y = reading.v[1],
                .z = reading.v[2],
                .status = mKind == ::rhizo::sensors::Kind::Magnetometer ? SensorStatus::ACCURACY_LOW
                                                                        : SensorStatus::ACCURACY_HIGH,
        };
        event.payload.set<EventPayload::Tag::vec3>(vec3);
    }
    std::vector<Event> events{event};
    mCallback->postEvents(events);
}

ScopedAStatus Sensor::injectEvent(const Event& event) {
    if (event.sensorType == SensorType::ADDITIONAL_INFO) {
        return ScopedAStatus::ok();
        // When in OperationMode::NORMAL, SensorType::ADDITIONAL_INFO is used to push operation
        // environment data into the device.
    }
    // No sensor here supports data injection.
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

}  // namespace sensors
}  // namespace hardware
}  // namespace android
}  // namespace aidl
