package android.media.audiopolicy;

import android.media.AudioDeviceInfo;
import android.media.AudioFormat;

// compile-time stub for AudioMix
public class AudioMix {
    public static final int ROUTE_FLAG_RENDER = 0x1;
    public static final int ROUTE_FLAG_LOOP_BACK = 0x1 << 1;

    // forbid direct construction
    private AudioMix() {}

    public static class Builder {
        public Builder(AudioMixingRule rule) {}
        public Builder setFormat(AudioFormat format) { return this; }
        public Builder setRouteFlags(int routeFlags) { return this; }
        public Builder setDevice(AudioDeviceInfo device) { return this; }
        public AudioMix build() { return null; }
    }
}
