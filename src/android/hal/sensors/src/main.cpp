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

#include <android/binder_manager.h>
#include <android/binder_process.h>

#include <string>

#include "conf.h"
#include "log.h"

using aidl::android::hardware::sensors::Sensors;

int main() {
    ABinderProcess_setThreadPoolMaxThreadCount(0);

    ::rhizo::sensors::Conf conf;
    ::rhizo::sensors::ConfError err;
    bool accepted = ::rhizo::sensors::loadConf(::rhizo::sensors::kConfPath, &conf, &err);
    if (!accepted) {
        conf = ::rhizo::sensors::Conf();
        ::rhizo::sensors::klogf("%s rejected (line %d): %s; serving no sensors", ::rhizo::sensors::kConfPath,
                                err.line, err.detail.c_str());
    }

    // Make the sensors service; reading starts only when the framework activates a sensor
    auto sensor = ndk::SharedRefBase::make<Sensors>(conf);
    const std::string sensorName = std::string() + Sensors::descriptor + "/default";
    binder_status_t status =
            AServiceManager_addService(sensor->asBinder().get(), sensorName.c_str());
    if (status != STATUS_OK) {
        ::rhizo::sensors::klogf("RHIZO_MARKER sensors_hal=register_failed status=%d", status);
        return EXIT_FAILURE;
    }
    if (accepted) {
        ::rhizo::sensors::klogf("RHIZO_MARKER sensors_hal=serving count=%zu", sensor->sensorCount());
        for (const auto& s : ::rhizo::sensors::servedSensors(conf)) {
            ::rhizo::sensors::klogf("sensor %d: %s", s.handle, s.name.c_str());
        }
    } else {
        ::rhizo::sensors::klogf("RHIZO_MARKER sensors_hal=rejected reason=%s", err.code.c_str());
    }

    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;  // should not reach
}
