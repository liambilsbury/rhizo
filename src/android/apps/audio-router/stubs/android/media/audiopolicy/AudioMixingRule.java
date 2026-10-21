package android.media.audiopolicy;

// compile-time stub for AudioMixingRule
public class AudioMixingRule {
    public static final int RULE_MATCH_UID = 0x1 << 2;

    // forbid direct construction
    private AudioMixingRule() {}

    public static class Builder {
        public Builder() {}
        public Builder addMixRule(int rule, Object property) { return this; }
        public AudioMixingRule build() { return null; }
    }
}
