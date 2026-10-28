package com.rhizo.networklocation;

import android.content.Context;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.location.LocationRequest;
import android.location.provider.LocationProviderBase;
import android.location.provider.ProviderProperties;
import android.location.provider.ProviderRequest;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import java.io.PrintWriter;

// report the gnss HAL's host gps fixes as network fixes
public final class NetworkLocationProvider extends LocationProviderBase implements LocationListener, Runnable {
    static final String TAG = "RhizoNetworkLocation";
    private static final long OFF = Long.MAX_VALUE;
    private static final long RETRY_MS = 5000;
    private static final ProviderProperties PROPERTIES = new ProviderProperties.Builder()
            .setHasNetworkRequirement(true)
            .setPowerUsage(ProviderProperties.POWER_USAGE_LOW)
            .setAccuracy(ProviderProperties.ACCURACY_COARSE)
            .build();

    private final Object lock = new Object();
    private final Context context;
    private final LocationManager lm;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private long wantMs = OFF;
    private int quality;
    private long gpsMs = OFF;
    private boolean refusedLogged;
    private long forwarded;
    private long lastForwardedAt;

    NetworkLocationProvider(Context context) {
        super(context, TAG, PROPERTIES);
        this.context = context;
        this.lm = context.getSystemService(LocationManager.class);
    }

    // apply the framework's merged request
    @Override
    public void onSetRequest(ProviderRequest request) {
        synchronized (lock) {
            wantMs = request.isActive() ? request.getIntervalMillis() : OFF;
            quality = request.getQuality();
            applyLocked();
        }
    }

    @Override
    public void onFlush(OnFlushCompleteCallback callback) {
        callback.onFlushComplete();
    }

    @Override
    public void onSendExtraCommand(String command, Bundle extras) {}

    // drop the gps request
    void stop() {
        synchronized (lock) {
            wantMs = OFF;
            applyLocked();
        }
    }

    // retry a refused gps request
    @Override
    public void run() {
        synchronized (lock) {
            applyLocked();
        }
    }

    // hold gps at the request's interval
    private void applyLocked() {
        if (wantMs == gpsMs) {
            return;
        }
        handler.removeCallbacks(this);
        if (gpsMs != OFF) {
            lm.removeUpdates(this);
            gpsMs = OFF;
            Log.i(TAG, "gps request removed");
        }
        if (wantMs == OFF) {
            refusedLogged = false;
            return;
        }
        LocationRequest gps = new LocationRequest.Builder(wantMs).setQuality(quality).build();
        try {
            lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, gps, context.getMainExecutor(), this);
            gpsMs = wantMs;
            refusedLogged = false;
            Log.i(TAG, "gps request interval_ms=" + wantMs);
        } catch (SecurityException | IllegalArgumentException e) {
            if (!refusedLogged) {
                Log.w(TAG, "gps request refused (" + e.getClass().getSimpleName() + "), retrying every "
                        + RETRY_MS + " ms while network location is asked for");
                refusedLogged = true;
            }
            handler.postDelayed(this, RETRY_MS);
        }
    }

    // report each gps fix as a network fix
    @Override
    public void onLocationChanged(Location gps) {
        Location fix = asNetwork(gps);
        synchronized (lock) {
            if (gpsMs == OFF || fix == null) {
                return;
            }
            forwarded++;
            lastForwardedAt = SystemClock.elapsedRealtime();
        }
        reportLocation(fix);
    }

    // copy a gps fix into a network fix
    static Location asNetwork(Location gps) {
        if (!gps.hasAccuracy()) {
            return null;
        }
        Location fix = new Location(LocationManager.NETWORK_PROVIDER);
        fix.setLatitude(gps.getLatitude());
        fix.setLongitude(gps.getLongitude());
        fix.setAccuracy(gps.getAccuracy());
        fix.setTime(gps.getTime());
        fix.setElapsedRealtimeNanos(gps.getElapsedRealtimeNanos());
        if (gps.hasElapsedRealtimeUncertaintyNanos()) {
            fix.setElapsedRealtimeUncertaintyNanos(gps.getElapsedRealtimeUncertaintyNanos());
        }
        if (gps.hasAltitude()) {
            fix.setAltitude(gps.getAltitude());
            if (gps.hasVerticalAccuracy()) {
                fix.setVerticalAccuracyMeters(gps.getVerticalAccuracyMeters());
            }
        }
        if (gps.hasSpeed()) {
            fix.setSpeed(gps.getSpeed());
            if (gps.hasSpeedAccuracy()) {
                fix.setSpeedAccuracyMetersPerSecond(gps.getSpeedAccuracyMetersPerSecond());
            }
        }
        if (gps.hasBearing()) {
            fix.setBearing(gps.getBearing());
            if (gps.hasBearingAccuracy()) {
                fix.setBearingAccuracyDegrees(gps.getBearingAccuracyDegrees());
            }
        }
        fix.setMock(gps.isMock());
        return fix;
    }

    void dump(PrintWriter pw) {
        synchronized (lock) {
            pw.println("network_interval_ms=" + (wantMs == OFF ? "off" : Long.toString(wantMs))
                    + " gps_interval_ms=" + (gpsMs == OFF ? "off" : Long.toString(gpsMs))
                    + " forwarded=" + forwarded
                    + " last_forward_age_ms="
                    + (forwarded == 0 ? "none" : Long.toString(SystemClock.elapsedRealtime() - lastForwardedAt)));
        }
    }
}
