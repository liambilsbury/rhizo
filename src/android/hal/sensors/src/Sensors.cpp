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

#include "Sensors.h"

#include <aidl/android/hardware/common/fmq/SynchronizedReadWrite.h>

#include "log.h"

using ::aidl::android::hardware::common::fmq::MQDescriptor;
using ::aidl::android::hardware::common::fmq::SynchronizedReadWrite;
using ::aidl::android::hardware::sensors::Event;
using ::aidl::android::hardware::sensors::ISensors;
using ::aidl::android::hardware::sensors::ISensorsCallback;
using ::aidl::android::hardware::sensors::SensorInfo;
using ::ndk::ScopedAStatus;

namespace aidl {
namespace android {
namespace hardware {
namespace sensors {

Sensors::Sensors(const ::rhizo::sensors::Conf& conf) : mConf(conf) {
    for (const ::rhizo::sensors::ServedSensor& served : ::rhizo::sensors::servedSensors(mConf)) {
        auto sensor = std::make_shared<Sensor>(mConf.sensors[served.confIndex], served, this);
        mList.push_back(sensor->getSensorInfo());
        mSensors[served.handle] = sensor;
    }
}

void Sensors::postEvents(const std::vector<Event>& events) {
    std::lock_guard<std::mutex> lock(mWriteLock);
    if (mEventQueue == nullptr || events.empty()) {
        return;
    }
    if (mEventQueue->write(&events.front(), events.size())) {
        if (mEventQueueFlag != nullptr) {
            mEventQueueFlag->wake(
                    static_cast<uint32_t>(BnSensors::EVENT_QUEUE_FLAG_BITS_READ_AND_PROCESS));
        }
        return;
    }
    // A full queue: the framework is not reading. Drop rather than block a poll thread.
    if (mDropped++ % 1000 == 0) {
        ::rhizo::sensors::klogf("event queue full: %llu events dropped so far",
                                static_cast<unsigned long long>(mDropped));
    }
}

ScopedAStatus Sensors::activate(int32_t in_sensorHandle, bool in_enabled) {
    auto sensor = mSensors.find(in_sensorHandle);
    if (sensor != mSensors.end()) {
        sensor->second->activate(in_enabled);
        return ScopedAStatus::ok();
    }

    return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
}

ScopedAStatus Sensors::batch(int32_t in_sensorHandle, int64_t in_samplingPeriodNs,
                             int64_t in_maxReportLatencyNs) {
    auto sensor = mSensors.find(in_sensorHandle);
    if (sensor != mSensors.end()) {
        if (in_samplingPeriodNs < 0 || in_maxReportLatencyNs < 0) {
            return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        }
        // No FIFO: the latency is ignored and every reading streams.
        sensor->second->batch(in_samplingPeriodNs);
        return ScopedAStatus::ok();
    }

    return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
}

ScopedAStatus Sensors::configDirectReport(int32_t /* in_sensorHandle */,
                                          int32_t /* in_channelHandle */,
                                          ISensors::RateLevel /* in_rate */,
                                          int32_t* _aidl_return) {
    *_aidl_return = EX_UNSUPPORTED_OPERATION;

    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

ScopedAStatus Sensors::flush(int32_t in_sensorHandle) {
    auto sensor = mSensors.find(in_sensorHandle);
    if (sensor != mSensors.end()) {
        return sensor->second->flush();
    }

    return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
}

ScopedAStatus Sensors::getSensorsList(std::vector<SensorInfo>* _aidl_return) {
    *_aidl_return = mList;
    return ScopedAStatus::ok();
}

ScopedAStatus Sensors::initialize(
        const MQDescriptor<Event, SynchronizedReadWrite>& in_eventQueueDescriptor,
        const MQDescriptor<int32_t, SynchronizedReadWrite>& in_wakeLockDescriptor,
        const std::shared_ptr<::aidl::android::hardware::sensors::ISensorsCallback>&
                in_sensorsCallback) {
    ::rhizo::sensors::klogf("initialize: %zu sensors, every one disabled", mList.size());
    ScopedAStatus result = ScopedAStatus::ok();

    // Ensure that all sensors are disabled, and that no flush queued for the old queue reaches the new one.
    for (auto sensor : mSensors) {
        sensor.second->reset();
    }

    // Save a reference to the callback
    mCallback = in_sensorsCallback;

    {
        // Hold the lock to ensure that re-creation of event flag is atomic
        std::lock_guard<std::mutex> lock(mWriteLock);

        mEventQueue = std::make_unique<AidlMessageQueue<Event, SynchronizedReadWrite>>(
                in_eventQueueDescriptor, true /* resetPointers */);

        // Ensure that any existing EventFlag is properly deleted
        deleteEventFlagLocked();

        // Create the EventFlag that is used to signal to the framework that sensor events have been
        // written to the Event FMQ
        if (!mEventQueue->isValid() || mEventQueue->getEventFlagWord() == nullptr ||
            EventFlag::createEventFlag(mEventQueue->getEventFlagWord(), &mEventQueueFlag) != OK) {
            result = ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        }

        // The Wake Lock FMQ the framework writes when it has handled WAKE_UP events; no sensor here is wake-up,
        // so it is mapped (a bad descriptor is refused) and never read.
        mWakeLockQueue = std::make_unique<AidlMessageQueue<int32_t, SynchronizedReadWrite>>(
                in_wakeLockDescriptor, true /* resetPointers */);

        if (!mCallback || !mEventQueue || !mWakeLockQueue || !mWakeLockQueue->isValid() ||
            mEventQueueFlag == nullptr) {
            result = ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        }
        if (!mEventQueue->isValid()) {
            mEventQueue.reset();
        }
    }

    return result;
}

ScopedAStatus Sensors::injectSensorData(const Event& in_event) {
    auto sensor = mSensors.find(in_event.sensorHandle);
    if (sensor != mSensors.end()) {
        return sensor->second->injectEvent(in_event);
    }
    return ScopedAStatus::fromServiceSpecificError(static_cast<int32_t>(ERROR_BAD_VALUE));
}

ScopedAStatus Sensors::registerDirectChannel(const ISensors::SharedMemInfo& /* in_mem */,
                                             int32_t* _aidl_return) {
    *_aidl_return = EX_UNSUPPORTED_OPERATION;

    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

ScopedAStatus Sensors::setOperationMode(OperationMode in_mode) {
    switch (in_mode) {
        case OperationMode::NORMAL:
            return ScopedAStatus::ok();
        case OperationMode::DATA_INJECTION:
            // No sensor carries SENSOR_FLAG_BITS_DATA_INJECTION.
            return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    }
    return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
}

ScopedAStatus Sensors::unregisterDirectChannel(int32_t /* in_channelHandle */) {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

}  // namespace sensors
}  // namespace hardware
}  // namespace android
}  // namespace aidl
