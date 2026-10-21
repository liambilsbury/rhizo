package android.companion.virtual.camera;

import java.io.Closeable;

// compile-time stub of VirtualCamera
public final class VirtualCamera implements Closeable {
    // forbid direct construction
    private VirtualCamera() {}

    // return null in place of a camera id
    public String getId() { return null; }
    @Override public void close() {}
}
