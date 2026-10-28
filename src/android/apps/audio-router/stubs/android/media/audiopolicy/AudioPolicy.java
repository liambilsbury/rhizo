package android.media.audiopolicy;

import android.content.Context;

// compile-time stub for AudioPolicy
public class AudioPolicy {
    // forbid direct construction
    private AudioPolicy() {}

    // report success without attaching the mixes
    public int attachMixes(java.util.List<AudioMix> mixes) { return 0; }
    // report success without detaching the mixes
    public int detachMixes(java.util.List<AudioMix> mixes) { return 0; }

    public static class Builder {
        public Builder(Context context) {}
        public Builder addMix(AudioMix mix) { return this; }
        public AudioPolicy build() { return null; }
    }
}
