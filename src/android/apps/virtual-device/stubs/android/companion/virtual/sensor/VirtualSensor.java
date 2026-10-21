package android.companion.virtual.sensor;

// compile-time stub of VirtualSensor
public final class VirtualSensor {
    // forbid direct construction
    private VirtualSensor() {}

    // return 0 in place of a sensor type
    public int getType() { return 0; }
    // drop the event
    public void sendEvent(VirtualSensorEvent event) {}
}
