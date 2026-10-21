package android.companion.virtual;

import android.companion.virtual.sensor.VirtualSensorCallback;
import android.companion.virtual.sensor.VirtualSensorConfig;

import java.util.concurrent.Executor;

// compile-time stub of VirtualDeviceParams
public final class VirtualDeviceParams {
    public static final int LOCK_STATE_ALWAYS_UNLOCKED = 1;

    // forbid direct construction
    private VirtualDeviceParams() {}

    public static final class Builder {
        public Builder() {}
        public Builder addVirtualSensorConfig(VirtualSensorConfig config) { return this; }
        public Builder setVirtualSensorCallback(Executor executor, VirtualSensorCallback callback) { return this; }
        public Builder setLockState(int lockState) { return this; }
        public VirtualDeviceParams build() { return null; }
    }
}
