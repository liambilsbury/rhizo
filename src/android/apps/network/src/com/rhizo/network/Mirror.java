package com.rhizo.network;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.wifi.SupplicantState;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.util.Log;

import java.util.List;

// receive the host's mirrored SSID and Wi-Fi settings resets
public class Mirror extends BroadcastReceiver {
    static final String TAG = "RhizoNetwork";
    static final String ACTION_RESET = "android.net.wifi.action.NETWORK_SETTINGS_RESET";
    static final String PROVISIONING = "android.permission.NETWORK_CARRIER_PROVISIONING";
    static final int RESULT_BAD_REQUEST = 1;
    static final int RESULT_NOT_PROVISIONED = 2;
    static final int RESULT_WIFI_REFUSED = 3;
    static final int ATTEMPTS = 16;
    static final long RETRY_MS = 500;

    private static final Object LOCK = new Object();

    // the code and summary of a broadcast result
    static final class Outcome {
        final int code;
        final String data;

        Outcome(int code, String data) {
            this.code = code;
            this.data = data;
        }
    }

    // a request run on a worker thread
    static final class Apply implements Runnable {
        private final Context mContext;
        private final Intent mIntent;
        private final boolean mOrdered;
        private final PendingResult mPending;

        Apply(Context context, Intent intent, boolean ordered, PendingResult pending) {
            mContext = context;
            mIntent = intent;
            mOrdered = ordered;
            mPending = pending;
        }

        @Override
        public void run() {
            Outcome outcome;
            synchronized (LOCK) {
                outcome = handle(mContext, mIntent);
            }
            if (mOrdered) {
                mPending.setResult(outcome.code, outcome.data, null);
            }
            mPending.finish();
        }
    }

    // apply the request off the main thread
    @Override
    public void onReceive(Context context, Intent intent) {
        boolean ordered = isOrderedBroadcast();
        new Thread(new Apply(context.getApplicationContext(), intent, ordered, goAsync()),
                "rhizo-mirror").start();
    }

    // run a mirror or reset request
    static Outcome handle(Context ctx, Intent intent) {
        boolean debug = intent.getBooleanExtra("debug", false);
        boolean reset = ACTION_RESET.equals(intent.getAction());
        String what = reset ? "reset" : "mirror";
        Kept kept = new Kept(ctx);
        String hex;
        if (reset) {
            hex = kept.current();
            if (hex == null) {
                Log.i(TAG, "reset: nothing mirrored yet, nothing to re-add");
                return new Outcome(Activity.RESULT_OK, "ok nothing-mirrored");
            }
        } else {
            hex = Kept.normalize(intent.getStringExtra("ssid_hex"));
            if (hex == null) {
                Log.e(TAG, "mirror: refused, ssid_hex is not 1-32 bytes of hex");
                return new Outcome(RESULT_BAD_REQUEST, "bad-ssid");
            }
        }
        // an add made without this permission latches the app unapproved until its data is cleared
        if (ctx.checkSelfPermission(PROVISIONING) != PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, what + ": refused, " + PROVISIONING
                    + " is not granted (privapp allowlist missing?), no suggestion added");
            return new Outcome(RESULT_NOT_PROVISIONED, "not-provisioned");
        }
        List<String> want = reset ? Kept.only(hex) : kept.promote(hex);
        WifiManager wifi = ctx.getSystemService(WifiManager.class);
        boolean connected = !reset && isConnected(wifi);
        int status = WifiManager.STATUS_NETWORK_SUGGESTIONS_ERROR_INTERNAL;
        for (int attempt = 1; attempt <= ATTEMPTS; attempt++) {
            status = Suggestions.reconcile(wifi, want, hex, connected, debug, what);
            if (status != WifiManager.STATUS_NETWORK_SUGGESTIONS_ERROR_INTERNAL) {
                break;
            }
            Log.w(TAG, what + ": wifi user data not loaded yet, retry " + attempt + "/" + ATTEMPTS);
            try {
                Thread.sleep(RETRY_MS);
            } catch (InterruptedException e) {
                break;
            }
        }
        if (status != WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS) {
            Log.e(TAG, what + ": wifi refused the suggestions, status " + status);
            return new Outcome(RESULT_WIFI_REFUSED, "wifi-status=" + status);
        }
        kept.save(want);
        boolean reconnect = false;
        String revalidate = "-";
        if (!connected) {
            reconnect = wifi.reconnect();
            Log.i(TAG, what + ": reconnect requested=" + reconnect);
        } else if (!reset) {
            revalidate = revalidate(ctx);
            Log.i(TAG, what + ": revalidate " + revalidate);
        }
        Log.i(TAG, what + ": done kept=" + want.size() + " connected=" + connected
                + (debug ? " ssid_hex=" + hex : ""));
        return new Outcome(Activity.RESULT_OK, "ok kept=" + want.size()
                + " connected=" + (connected ? 1 : 0) + " reconnect=" + (reconnect ? 1 : 0)
                + " revalidate=" + revalidate);
    }

    // make NetworkMonitor re-validate the Wi-Fi network
    static String revalidate(Context ctx) {
        ConnectivityManager cm = ctx.getSystemService(ConnectivityManager.class);
        if (cm == null) {
            return "no-connectivity-service";
        }
        for (Network n : cm.getAllNetworks()) {
            NetworkCapabilities nc = cm.getNetworkCapabilities(n);
            if (nc == null || !nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                continue;
            }
            boolean validated = nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
            cm.reportNetworkConnectivity(n, !validated);
            return validated ? "requested(was-validated)" : "requested(was-unvalidated)";
        }
        return "no-wifi-network";
    }

    // return whether the station is associated
    static boolean isConnected(WifiManager wifi) {
        WifiInfo info = wifi.getConnectionInfo();
        return info != null && info.getSupplicantState() == SupplicantState.COMPLETED;
    }
}
