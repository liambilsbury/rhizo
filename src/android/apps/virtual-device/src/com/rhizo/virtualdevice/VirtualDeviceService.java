package com.rhizo.virtualdevice;

import android.app.Service;
import android.companion.AssociationInfo;
import android.companion.AssociationRequest;
import android.companion.CompanionDeviceManager;
import android.companion.virtual.VirtualDeviceManager;
import android.companion.virtual.VirtualDeviceParams;
import android.companion.virtual.camera.VirtualCamera;
import android.companion.virtual.camera.VirtualCameraCallback;
import android.companion.virtual.camera.VirtualCameraConfig;
import android.companion.virtual.sensor.VirtualSensor;
import android.companion.virtual.sensor.VirtualSensorCallback;
import android.companion.virtual.sensor.VirtualSensorConfig;
import android.companion.virtual.sensor.VirtualSensorEvent;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.PixelFormat;
import android.hardware.Sensor;
import android.hardware.camera2.CameraMetadata;
import android.media.Image;
import android.media.ImageWriter;
import android.os.FileObserver;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.SystemClock;
import android.view.Surface;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executor;

// service for virtual sensors and camera
public class VirtualDeviceService extends Service {

    private static final File DEVICE_DIR = new File("/vendor/etc/rhizo-device-state");
    private static final File SENSOR_ACCEL = new File(DEVICE_DIR, "sensor-accel.conf");
    private static final File SENSOR_GYRO = new File(DEVICE_DIR, "sensor-gyro.conf");
    private static final File SENSOR_LIGHT = new File(DEVICE_DIR, "sensor-light.conf");
    private static final File CAMERA_FRAME = new File(DEVICE_DIR, "camera.frame");

    private static final int CAMERA_WIDTH = 640;
    private static final int CAMERA_HEIGHT = 480;
    private static final int CAMERA_MAX_FPS = 5;

    private Handler handler;
    private boolean started;
    private DeviceDirObserver deviceDirObserver;

    private final Executor handlerExecutor = new Executor() {
        @Override
        public void execute(Runnable command) {
            handler.post(command);
        }
    };

    private Object virtualDevice;
    private final Map<Integer, VirtualSensor> sensorsByType = new HashMap<>();
    private final Map<Integer, Boolean> sensorEnabled = new HashMap<>();

    private VirtualCamera virtualCamera;
    private ImageWriter imageWriter;
    private int cameraStreamId = -1;
    private int cameraStreamWidth;
    private int cameraStreamHeight;
    private Bitmap cameraBitmap;
    private long cameraFrameMtime = -1;

    // return no binder
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // start the service thread and DeviceDirObserver
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (!started) {
            started = true;
            HandlerThread thread = new HandlerThread("rhizo-virtualdevice");
            thread.start();
            handler = new Handler(thread.getLooper());
            handler.post(new Runnable() {
                @Override
                public void run() {
                    associate();
                }
            });
            deviceDirObserver = new DeviceDirObserver(DEVICE_DIR.getAbsolutePath());
            deviceDirObserver.startWatching();
            handler.post(new Runnable() {
                @Override
                public void run() {
                    pollSensors();
                    pollCameraFrame();
                }
            });
        }
        return START_STICKY;
    }

    // FileObserver for the device-state directory
    private final class DeviceDirObserver extends FileObserver {
        DeviceDirObserver(String path) {
            super(path, FileObserver.CLOSE_WRITE | FileObserver.MOVED_TO);
        }

        @Override
        public void onEvent(int event, String path) {
            handler.post(new Runnable() {
                @Override
                public void run() {
                    pollSensors();
                    pollCameraFrame();
                }
            });
        }
    }

    // create the companion association and the virtual device
    private void associate() {
        CompanionDeviceManager cdm = getSystemService(CompanionDeviceManager.class);
        if (cdm == null) {
            Logs.e("RHIZO_VIRTUAL_DEVICE no CompanionDeviceManager service");
            return;
        }
        AssociationRequest request = new AssociationRequest.Builder()
                .setSelfManaged(true)
                .setDisplayName("Rhizo virtual device")
                .build();
        cdm.associate(request, new CompanionDeviceManager.Callback() {
            @Override
            public void onAssociationCreated(final AssociationInfo info) {
                Logs.i("RHIZO_VIRTUAL_DEVICE associated associationId=" + info.getId());
                handler.post(new Runnable() {
                    @Override
                    public void run() {
                        createVirtualDevice(info.getId());
                    }
                });
            }

            @Override
            public void onFailure(CharSequence error) {
                Logs.e("RHIZO_VIRTUAL_DEVICE association_failed error=" + error);
            }
        }, handler);
    }

    private final VirtualSensorCallback sensorCallback = new VirtualSensorCallback() {
        @Override
        public void onConfigurationChanged(VirtualSensor sensor, boolean enabled,
                Duration samplingPeriod, Duration batchReportLatency) {
            int type = sensor.getType();
            sensorEnabled.put(type, enabled);
            Logs.i("RHIZO_VIRTUAL_DEVICE sensor_configuration_changed type=" + type + " enabled=" + enabled);
        }
    };

    // create the virtual device with its sensors and camera
    private void createVirtualDevice(int associationId) {
        VirtualDeviceManager vdm = getSystemService(VirtualDeviceManager.class);
        if (vdm == null) {
            Logs.e("RHIZO_VIRTUAL_DEVICE no VirtualDeviceManager service");
            return;
        }
        List<VirtualSensorConfig> configs = new ArrayList<>();
        configs.add(new VirtualSensorConfig.Builder(Sensor.TYPE_ACCELEROMETER, "rhizo-accel").build());
        configs.add(new VirtualSensorConfig.Builder(Sensor.TYPE_GYROSCOPE, "rhizo-gyro").build());
        configs.add(new VirtualSensorConfig.Builder(Sensor.TYPE_LIGHT, "rhizo-light").build());
        VirtualDeviceParams.Builder paramsBuilder = new VirtualDeviceParams.Builder()
                .setVirtualSensorCallback(handlerExecutor, sensorCallback);
        for (VirtualSensorConfig cfg : configs) {
            paramsBuilder.addVirtualSensorConfig(cfg);
        }
        try {
            Object device = Vdm.createVirtualDevice(vdm, associationId, paramsBuilder.build());
            virtualDevice = device;
            for (VirtualSensor sensor : Vdm.getVirtualSensorList(device)) {
                sensorsByType.put(sensor.getType(), sensor);
                sensorEnabled.put(sensor.getType(), false);
            }
            Logs.i("RHIZO_VIRTUAL_DEVICE device_created deviceId=" + Vdm.getDeviceId(device)
                    + " sensors=" + sensorsByType.size());
        } catch (ReflectiveOperationException e) {
            Logs.e("RHIZO_VIRTUAL_DEVICE create_virtual_device_failed", e);
            return;
        }
        createVirtualCamera();
    }

    private final VirtualCameraCallback cameraCallback = new VirtualCameraCallback() {
        @Override
        public void onStreamConfigured(int streamId, Surface surface, int width, int height, int format) {
            onCameraStreamConfigured(streamId, surface, width, height);
        }

        @Override
        public void onProcessCaptureRequest(int streamId, long frameId) {
            writeCameraFrame();
        }

        @Override
        public void onStreamClosed(int streamId) {
            onCameraStreamClosed(streamId);
        }
    };

    // create the virtual back camera
    private void createVirtualCamera() {
        VirtualCameraConfig config = new VirtualCameraConfig.Builder("rhizo-camera")
                .addStreamConfig(CAMERA_WIDTH, CAMERA_HEIGHT, PixelFormat.RGBA_8888, CAMERA_MAX_FPS)
                .setLensFacing(CameraMetadata.LENS_FACING_BACK)
                .setVirtualCameraCallback(handlerExecutor, cameraCallback)
                .build();
        try {
            virtualCamera = Vdm.createVirtualCamera(virtualDevice, config);
            Logs.i("RHIZO_VIRTUAL_DEVICE camera_created");
        } catch (ReflectiveOperationException e) {
            Logs.e("RHIZO_VIRTUAL_DEVICE create_virtual_camera_failed", e);
        }
    }

    // replace the image writer for the configured stream
    private void onCameraStreamConfigured(int streamId, Surface surface, int width, int height) {
        Logs.i("RHIZO_VIRTUAL_DEVICE camera_stream_configured streamId=" + streamId
                + " " + width + "x" + height);
        if (imageWriter != null) {
            imageWriter.close();
        }
        cameraStreamId = streamId;
        cameraStreamWidth = width;
        cameraStreamHeight = height;
        imageWriter = ImageWriter.newInstance(surface, 2, PixelFormat.RGBA_8888);
        cameraFrameMtime = -1;
        reloadCameraFrame();
    }

    // close the image writer when its stream closes
    private void onCameraStreamClosed(int streamId) {
        Logs.i("RHIZO_VIRTUAL_DEVICE camera_stream_closed streamId=" + streamId);
        if (streamId == cameraStreamId && imageWriter != null) {
            imageWriter.close();
            imageWriter = null;
        }
    }

    // read KEY=value lines from a file
    private static Map<String, String> readKeyValueFile(File f) {
        Map<String, String> out = new HashMap<>();
        try (BufferedReader r = new BufferedReader(new FileReader(f))) {
            String line;
            while ((line = r.readLine()) != null) {
                int eq = line.indexOf('=');
                if (eq > 0) {
                    out.put(line.substring(0, eq).trim(), line.substring(eq + 1).trim());
                }
            }
        } catch (IOException e) {
        }
        return out;
    }

    // send the accelerometer, gyroscope and light values
    private void pollSensors() {
        sendVector(Sensor.TYPE_ACCELEROMETER, SENSOR_ACCEL, new String[]{"x", "y", "z"});
        sendVector(Sensor.TYPE_GYROSCOPE, SENSOR_GYRO, new String[]{"x", "y", "z"});
        sendVector(Sensor.TYPE_LIGHT, SENSOR_LIGHT, new String[]{"lux"});
    }

    // send a sensor event from file values
    private void sendVector(int sensorType, File file, String[] keys) {
        VirtualSensor sensor = sensorsByType.get(sensorType);
        if (sensor == null || !Boolean.TRUE.equals(sensorEnabled.get(sensorType))) {
            return;
        }
        Map<String, String> kv = readKeyValueFile(file);
        float[] values = new float[keys.length];
        for (int i = 0; i < keys.length; i++) {
            String raw = kv.get(keys[i]);
            if (raw == null) {
                return;
            }
            try {
                values[i] = Float.parseFloat(raw);
            } catch (NumberFormatException e) {
                Logs.e("RHIZO_VIRTUAL_DEVICE malformed " + file + " key=" + keys[i] + " value=" + raw);
                return;
            }
        }
        sensor.sendEvent(new VirtualSensorEvent.Builder(values)
                .setTimestampNanos(SystemClock.elapsedRealtimeNanos())
                .build());
    }

    // reload the camera frame when its file changed
    private void pollCameraFrame() {
        if (!CAMERA_FRAME.isFile()) {
            return;
        }
        long mtime = CAMERA_FRAME.lastModified();
        if (mtime == cameraFrameMtime) {
            return;
        }
        cameraFrameMtime = mtime;
        reloadCameraFrame();
    }

    // decode the camera frame file at the stream size
    private void reloadCameraFrame() {
        if (imageWriter == null || cameraStreamWidth == 0 || !CAMERA_FRAME.isFile()) {
            return;
        }
        Bitmap decoded = BitmapFactory.decodeFile(CAMERA_FRAME.getAbsolutePath());
        if (decoded == null) {
            Logs.e("RHIZO_VIRTUAL_DEVICE cannot decode " + CAMERA_FRAME + " as an image");
            return;
        }
        Bitmap scaled = Bitmap.createScaledBitmap(decoded, cameraStreamWidth, cameraStreamHeight, true);
        if (scaled != decoded) {
            decoded.recycle();
        }
        cameraBitmap = scaled;
        writeCameraFrame();
    }

    // write the host frame into a camera buffer
    private void writeCameraFrame() {
        if (imageWriter == null || cameraBitmap == null) {
            return;
        }
        Image image = imageWriter.dequeueInputImage();
        if (image == null) {
            return;
        }
        image.setTimestamp(SystemClock.elapsedRealtimeNanos());
        Image.Plane plane = image.getPlanes()[0];
        ByteBuffer buf = plane.getBuffer();
        int rowStride = plane.getRowStride();
        int pixelStride = plane.getPixelStride();
        int w = cameraStreamWidth, h = cameraStreamHeight;
        int[] pixels = new int[w * h];
        cameraBitmap.getPixels(pixels, 0, w, 0, 0, w, h);
        byte[] row = new byte[rowStride];
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int p = pixels[y * w + x];
                int o = x * pixelStride;
                row[o] = (byte) ((p >> 16) & 0xFF);
                row[o + 1] = (byte) ((p >> 8) & 0xFF);
                row[o + 2] = (byte) (p & 0xFF);
                row[o + 3] = (byte) ((p >> 24) & 0xFF);
            }
            buf.position(y * rowStride);
            buf.put(row, 0, rowStride);
        }
        imageWriter.queueInputImage(image);
    }

    // stop the observer and close the virtual device
    @Override
    public void onDestroy() {
        if (deviceDirObserver != null) {
            deviceDirObserver.stopWatching();
            deviceDirObserver = null;
        }
        if (imageWriter != null) {
            imageWriter.close();
            imageWriter = null;
        }
        if (virtualCamera != null) {
            virtualCamera.close();
            virtualCamera = null;
        }
        if (virtualDevice != null) {
            Vdm.closeVirtualDevice(virtualDevice);
            virtualDevice = null;
        }
        super.onDestroy();
    }
}
