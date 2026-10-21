package android.companion.virtual.sensor;

import java.time.Duration;

// compile-time stub of VirtualSensorCallback
public interface VirtualSensorCallback {
    void onConfigurationChanged(VirtualSensor sensor, boolean enabled,
            Duration samplingPeriod, Duration batchReportLatency);
}
