package android.companion.virtual.camera;

import android.view.Surface;

// compile-time stub of VirtualCameraCallback
public interface VirtualCameraCallback {
    void onStreamConfigured(int streamId, Surface surface, int width, int height, int format);
    default void onProcessCaptureRequest(int streamId, long frameId) {}
    void onStreamClosed(int streamId);
}
