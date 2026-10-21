package com.rhizo.devicereader;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Color;
import android.graphics.ImageFormat;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.media.Image;
import android.media.ImageReader;
import android.os.BatteryManager;
import android.os.Bundle;
import android.os.PowerManager;
import android.util.Log;
import android.view.Surface;
import android.widget.TextView;

import java.nio.ByteBuffer;
import java.util.Collections;
import java.util.List;

// activity for device injection tests
public class MainActivity extends Activity {
    private static final String TAG = "RhizoDeviceReader";
    private static final int CAMERA_WIDTH = 640;
    private static final int CAMERA_HEIGHT = 480;

    private BroadcastReceiver batteryReceiver;
    private PowerManager.OnThermalStatusChangedListener thermalListener;
    private LocationListener gpsListener;
    private SensorManager sensorManager;
    private final SensorEventListener accelListener = new VectorListener("accel");
    private final SensorEventListener gyroListener = new VectorListener("gyro");
    private SensorEventListener lightListener;
    private CameraDevice cameraDevice;
    private CameraCaptureSession cameraSession;
    private ImageReader cameraReader;

    // show the title text
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        TextView tv = new TextView(this);
        tv.setTextSize(24);
        tv.setTextColor(Color.WHITE);
        tv.setPadding(24, 24, 24, 24);
        tv.setText("RHIZO DEVICE READER\nwatching battery, thermal, gps");
        setContentView(tv);
    }

    // start all of the readers
    @Override
    protected void onResume() {
        super.onResume();
        startBattery();
        startThermal();
        startGps();
        startSensors();
        startCamera();
    }

    // stop all of the readers and release their listeners
    @Override
    protected void onPause() {
        super.onPause();
        if (batteryReceiver != null) { unregisterReceiver(batteryReceiver); batteryReceiver = null; }
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm != null && thermalListener != null) pm.removeThermalStatusListener(thermalListener);
        thermalListener = null;
        LocationManager lm = (LocationManager) getSystemService(Context.LOCATION_SERVICE);
        if (lm != null && gpsListener != null) lm.removeUpdates(gpsListener);
        gpsListener = null;
        stopSensors();
        stopCamera();
    }

    // register for battery change broadcasts
    private void startBattery() {
        batteryReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context ctx, Intent intent) { reportBattery(intent); }
        };
        Intent sticky = registerReceiver(batteryReceiver, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        if (sticky != null) reportBattery(sticky);
    }

    // log the battery level and charging state
    private void reportBattery(Intent intent) {
        int level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
        int scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1);
        int status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN);
        int pct = (level < 0 || scale <= 0) ? -1 : Math.round(100f * level / scale);
        String charging;
        if (status == BatteryManager.BATTERY_STATUS_CHARGING) charging = "charging";
        else if (status == BatteryManager.BATTERY_STATUS_DISCHARGING
                || status == BatteryManager.BATTERY_STATUS_NOT_CHARGING) charging = "discharging";
        else charging = "unknown";
        Log.i(TAG, "RHIZO_DEVICE_BATTERY level=" + pct + " charging=" + charging);
    }

    // register the thermal listener and log status
    private void startThermal() {
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm == null) {
            Log.e(TAG, "RHIZO_DEVICE_THERMAL_FAIL reason=no_power_manager");
            return;
        }
        thermalListener = new PowerManager.OnThermalStatusChangedListener() {
            @Override public void onThermalStatusChanged(int status) { reportThermal(status); }
        };
        pm.addThermalStatusListener(getMainExecutor(), thermalListener);
        reportThermal(pm.getCurrentThermalStatus());
    }

    // log the thermal status
    private void reportThermal(int status) {
        Log.i(TAG, "RHIZO_DEVICE_THERMAL status=" + status);
    }

    // register the GPS location listener
    private void startGps() {
        LocationManager lm = (LocationManager) getSystemService(Context.LOCATION_SERVICE);
        if (lm == null) {
            Log.e(TAG, "RHIZO_DEVICE_GPS_FAIL reason=no_location_manager");
            return;
        }
        gpsListener = new LocationListener() {
            @Override public void onLocationChanged(Location loc) { reportGps(loc); }
        };
        try {
            lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 0, 0, gpsListener);
        } catch (SecurityException e) {
            Log.e(TAG, "RHIZO_DEVICE_GPS_FAIL reason=" + e);
            gpsListener = null;
        } catch (IllegalArgumentException e) {
            String providers;
            try {
                providers = String.valueOf(lm.getAllProviders());
            } catch (RuntimeException inner) {
                providers = "<unreadable:" + inner + ">";
            }
            Log.i(TAG, "RHIZO_DEVICE_GPS absent=true providers=" + providers + " reason=" + e);
            gpsListener = null;
        }
    }

    // log the latitude and longitude of a location
    private void reportGps(Location loc) {
        Log.i(TAG, "RHIZO_DEVICE_GPS lat=" + loc.getLatitude() + " lon=" + loc.getLongitude());
    }

    // register the three sensor listeners
    private void startSensors() {
        sensorManager = (SensorManager) getSystemService(Context.SENSOR_SERVICE);
        if (sensorManager == null) {
            Log.e(TAG, "RHIZO_DEVICE_SENSOR_FAIL reason=no_sensor_manager");
            return;
        }
        registerOrAbsent(Sensor.TYPE_ACCELEROMETER, "accel", accelListener);
        registerOrAbsent(Sensor.TYPE_GYROSCOPE, "gyro", gyroListener);
        lightListener = new ScalarListener("light");
        registerOrAbsent(Sensor.TYPE_LIGHT, "light", lightListener);
    }

    // register the listener for a sensor type
    private void registerOrAbsent(int type, String name, SensorEventListener listener) {
        Sensor sensor = sensorManager.getDefaultSensor(type);
        if (sensor == null) {
            Log.i(TAG, "RHIZO_DEVICE_SENSOR_" + name.toUpperCase() + " absent=true");
            return;
        }
        sensorManager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_NORMAL);
    }

    // unregister the sensor listeners
    private void stopSensors() {
        if (sensorManager == null) return;
        sensorManager.unregisterListener(accelListener);
        sensorManager.unregisterListener(gyroListener);
        if (lightListener != null) sensorManager.unregisterListener(lightListener);
        lightListener = null;
        sensorManager = null;
    }

    // logging listener for vector sensors
    private final class VectorListener implements SensorEventListener {
        private final String name;
        VectorListener(String name) { this.name = name; }
        @Override
        public void onSensorChanged(SensorEvent event) {
            float x = event.values.length > 0 ? event.values[0] : 0f;
            float y = event.values.length > 1 ? event.values[1] : 0f;
            float z = event.values.length > 2 ? event.values[2] : 0f;
            Log.i(TAG, "RHIZO_DEVICE_SENSOR_" + name.toUpperCase()
                    + " x=" + x + " y=" + y + " z=" + z);
        }
        @Override public void onAccuracyChanged(Sensor sensor, int accuracy) {}
    }

    // logging listener for scalar sensors
    private final class ScalarListener implements SensorEventListener {
        private final String name;
        ScalarListener(String name) { this.name = name; }
        @Override
        public void onSensorChanged(SensorEvent event) {
            float v = event.values.length > 0 ? event.values[0] : 0f;
            Log.i(TAG, "RHIZO_DEVICE_SENSOR_" + name.toUpperCase() + " lux=" + v);
        }
        @Override public void onAccuracyChanged(Sensor sensor, int accuracy) {}
    }

    // open the camera and log frame brightness
    private void startCamera() {
        CameraManager cm = (CameraManager) getSystemService(Context.CAMERA_SERVICE);
        if (cm == null) {
            Log.e(TAG, "RHIZO_DEVICE_CAMERA_FAIL reason=no_camera_manager");
            return;
        }
        String id;
        try {
            String[] ids = cm.getCameraIdList();
            if (ids.length == 0) {
                Log.i(TAG, "RHIZO_DEVICE_CAMERA absent=true");
                return;
            }
            id = ids[0];
        } catch (CameraAccessException e) {
            Log.e(TAG, "RHIZO_DEVICE_CAMERA_FAIL reason=" + e);
            return;
        }
        cameraReader = ImageReader.newInstance(CAMERA_WIDTH, CAMERA_HEIGHT, ImageFormat.YUV_420_888, 2);
        cameraReader.setOnImageAvailableListener(new ImageReader.OnImageAvailableListener() {
            @Override
            public void onImageAvailable(ImageReader reader) {
                onCameraFrame(reader);
            }
        }, null);
        try {
            cm.openCamera(id, new CameraDevice.StateCallback() {
                @Override public void onOpened(CameraDevice device) { onCameraOpened(device); }
                @Override public void onDisconnected(CameraDevice device) { device.close(); }
                @Override
                public void onError(CameraDevice device, int error) {
                    Log.e(TAG, "RHIZO_DEVICE_CAMERA_FAIL reason=onError:" + error);
                    device.close();
                }
            }, null);
        } catch (CameraAccessException | SecurityException e) {
            Log.e(TAG, "RHIZO_DEVICE_CAMERA_FAIL reason=" + e);
        }
    }

    // create a capture session on the opened camera
    private void onCameraOpened(CameraDevice device) {
        cameraDevice = device;
        try {
            List<Surface> surfaces = Collections.singletonList(cameraReader.getSurface());
            device.createCaptureSession(surfaces, new CameraCaptureSession.StateCallback() {
                @Override public void onConfigured(CameraCaptureSession session) { onSessionConfigured(session); }
                @Override
                public void onConfigureFailed(CameraCaptureSession session) {
                    Log.e(TAG, "RHIZO_DEVICE_CAMERA_FAIL reason=session_configure_failed");
                }
            }, null);
        } catch (CameraAccessException e) {
            Log.e(TAG, "RHIZO_DEVICE_CAMERA_FAIL reason=" + e);
        }
    }

    // start a repeating preview request into the image reader
    private void onSessionConfigured(CameraCaptureSession session) {
        cameraSession = session;
        try {
            CaptureRequest.Builder req = cameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            req.addTarget(cameraReader.getSurface());
            session.setRepeatingRequest(req.build(), null, null);
        } catch (CameraAccessException e) {
            Log.e(TAG, "RHIZO_DEVICE_CAMERA_FAIL reason=" + e);
        }
    }

    // log the brightness of the camera frame
    private void onCameraFrame(ImageReader reader) {
        Image image = reader.acquireLatestImage();
        if (image == null) return;
        try {
            Image.Plane yPlane = image.getPlanes()[0];
            ByteBuffer buf = yPlane.getBuffer();
            int rowStride = yPlane.getRowStride();
            int pixelStride = yPlane.getPixelStride();
            int w = image.getWidth(), h = image.getHeight();
            long sum = 0;
            int sampled = 0;
            for (int y = 0; y < h; y += 8) {
                int rowStart = y * rowStride;
                for (int x = 0; x < w; x += 8) {
                    sum += buf.get(rowStart + x * pixelStride) & 0xFF;
                    sampled++;
                }
            }
            int avgLuma = sampled > 0 ? (int) (sum / sampled) : -1;
            int brightness = avgLuma >= 128 ? 1 : 0;
            Log.i(TAG, "RHIZO_DEVICE_CAMERA brightness=" + brightness + " avg_luma=" + avgLuma);
        } finally {
            image.close();
        }
    }

    // close the camera session, device and image reader
    private void stopCamera() {
        if (cameraSession != null) { cameraSession.close(); cameraSession = null; }
        if (cameraDevice != null) { cameraDevice.close(); cameraDevice = null; }
        if (cameraReader != null) { cameraReader.close(); cameraReader = null; }
    }
}
