package com.rhizo.virtualdevice;

import android.companion.virtual.VirtualDeviceManager;
import android.companion.virtual.VirtualDeviceParams;
import android.companion.virtual.camera.VirtualCamera;
import android.companion.virtual.camera.VirtualCameraConfig;
import android.companion.virtual.sensor.VirtualSensor;

import java.lang.reflect.Method;
import java.util.List;

// reflection calls for VirtualDeviceManager
final class Vdm {
    // forbid instances
    private Vdm() {}

    static Object createVirtualDevice(VirtualDeviceManager vdm, int associationId, VirtualDeviceParams params)
            throws ReflectiveOperationException {
        Method create = vdm.getClass()
                .getMethod("createVirtualDevice", int.class, VirtualDeviceParams.class);
        return create.invoke(vdm, associationId, params);
    }

    // return the device's VirtualSensor list
    @SuppressWarnings("unchecked")
    static List<VirtualSensor> getVirtualSensorList(Object virtualDevice) throws ReflectiveOperationException {
        return (List<VirtualSensor>) virtualDevice.getClass().getMethod("getVirtualSensorList").invoke(virtualDevice);
    }

    static int getDeviceId(Object virtualDevice) throws ReflectiveOperationException {
        return (int) virtualDevice.getClass().getMethod("getDeviceId").invoke(virtualDevice);
    }

    static VirtualCamera createVirtualCamera(Object virtualDevice, VirtualCameraConfig config)
            throws ReflectiveOperationException {
        Method m = virtualDevice.getClass().getMethod("createVirtualCamera", VirtualCameraConfig.class);
        return (VirtualCamera) m.invoke(virtualDevice, config);
    }

    static void closeVirtualDevice(Object virtualDevice) {
        try {
            virtualDevice.getClass().getMethod("close").invoke(virtualDevice);
        } catch (ReflectiveOperationException e) {
            Logs.e("RHIZO_VIRTUAL_DEVICE close_virtual_device_failed", e);
        }
    }
}
