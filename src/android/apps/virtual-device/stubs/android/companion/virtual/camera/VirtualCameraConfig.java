package android.companion.virtual.camera;

import java.util.concurrent.Executor;

// compile-time stub of VirtualCameraConfig
public final class VirtualCameraConfig {
    // forbid direct construction
    private VirtualCameraConfig() {}

    public static final class Builder {
        public Builder(String name) {}
        public Builder addStreamConfig(int width, int height, int format, int maximumFramesPerSecond) { return this; }
        public Builder setLensFacing(int lensFacing) { return this; }
        public Builder setVirtualCameraCallback(Executor executor, VirtualCameraCallback callback) { return this; }
        public VirtualCameraConfig build() { return null; }
    }
}
