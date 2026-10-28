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

#include <aidl/android/hardware/common/fmq/SynchronizedReadWrite.h>
#include <aidl/android/hardware/sensors/BnSensors.h>
#include <fmq/AidlMessageQueue.h>
#include <fmq/EventFlag.h>
#include <log/log.h>

#include <map>
#include <memory>
#include <mutex>
#include <vector>

#include "Sensor.h"
#include "conf.h"

namespace aidl {
namespace android {
namespace hardware {
namespace sensors {

using aidl::android::hardware::common::fmq::SynchronizedReadWrite;
using ::android::AidlMessageQueue;
using ::android::OK;
using ::android::status_t;
using ::android::hardware::EventFlag;

class Sensors : public BnSensors, public ISensorsEventCallback {
  public:
    // serve the conf's sensors (an empty conf serves none)
    explicit Sensors(const ::rhizo::sensors::Conf& conf);

    // join every poll thread first, so none posts to a queue being torn down
    virtual ~Sensors() {
        mSensors.clear();
        deleteEventFlag();
    }

    ::ndk::ScopedAStatus activate(int32_t in_sensorHandle, bool in_enabled) override;
    ::ndk::ScopedAStatus batch(int32_t in_sensorHandle, int64_t in_samplingPeriodNs,
                               int64_t in_maxReportLatencyNs) override;
    ::ndk::ScopedAStatus configDirectReport(
            int32_t in_sensorHandle, int32_t in_channelHandle,
            ::aidl::android::hardware::sensors::ISensors::RateLevel in_rate,
            int32_t* _aidl_return) override;
    ::ndk::ScopedAStatus flush(int32_t in_sensorHandle) override;
    ::ndk::ScopedAStatus getSensorsList(
            std::vector<::aidl::android::hardware::sensors::SensorInfo>* _aidl_return) override;
    ::ndk::ScopedAStatus initialize(
            const ::aidl::android::hardware::common::fmq::MQDescriptor<
                    ::aidl::android::hardware::sensors::Event,
                    ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>&
                    in_eventQueueDescriptor,
            const ::aidl::android::hardware::common::fmq::MQDescriptor<
                    int32_t, ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>&
                    in_wakeLockDescriptor,
            const std::shared_ptr<::aidl::android::hardware::sensors::ISensorsCallback>&
                    in_sensorsCallback) override;
    ::ndk::ScopedAStatus injectSensorData(
            const ::aidl::android::hardware::sensors::Event& in_event) override;
    ::ndk::ScopedAStatus registerDirectChannel(
            const ::aidl::android::hardware::sensors::ISensors::SharedMemInfo& in_mem,
            int32_t* _aidl_return) override;
    ::ndk::ScopedAStatus setOperationMode(
            ::aidl::android::hardware::sensors::ISensors::OperationMode in_mode) override;
    ::ndk::ScopedAStatus unregisterDirectChannel(int32_t in_channelHandle) override;

    void postEvents(const std::vector<Event>& events) override;

    // how many sensors getSensorsList returns
    size_t sensorCount() const { return mList.size(); }

  protected:
    // Utility function to delete the Event Flag
    void deleteEventFlag() {
        // Hold the lock to ensure we don't delete the flag while it's being used in postEvents()
        std::lock_guard<std::mutex> lock(mWriteLock);
        deleteEventFlagLocked();
    }

    // Expects mWriteLock to be locked prior to invocation
    void deleteEventFlagLocked() {
        if (mEventQueueFlag != nullptr) {
            status_t status = EventFlag::deleteEventFlag(&mEventQueueFlag);
            if (status != OK) {
                ALOGI("Failed to delete event flag: %d", status);
            }
        }
    }

  private:
    // The conf the sensors read their channels from; it outlives them
    const ::rhizo::sensors::Conf mConf;
    // The Event FMQ where sensor events are written
    std::unique_ptr<AidlMessageQueue<Event, SynchronizedReadWrite>> mEventQueue;
    // The Wake Lock FMQ; mapped and kept, never read, since no sensor is wake-up
    std::unique_ptr<AidlMessageQueue<int32_t, SynchronizedReadWrite>> mWakeLockQueue;
    // Event Flag to signal to the framework when sensor events are available to be read
    EventFlag* mEventQueueFlag = nullptr;
    // Callback for asynchronous events, such as dynamic sensor connections.
    std::shared_ptr<::aidl::android::hardware::sensors::ISensorsCallback> mCallback;
    // The served list, in getSensorsList order
    std::vector<SensorInfo> mList;
    // Lock to protect writes to the FMQs.
    std::mutex mWriteLock;
    // Events dropped on a full queue
    uint64_t mDropped = 0;
    // A map of the available sensors; last, so it is destroyed (its threads joined) before everything above
    std::map<int32_t, std::shared_ptr<Sensor>> mSensors;
};

}  // namespace sensors
}  // namespace hardware
}  // namespace android
}  // namespace aidl
