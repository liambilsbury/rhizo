package com.rhizo.vpntest;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.net.VpnService;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

// activity for VpnService system tests
public class MainActivity extends Activity {
    private static final String TAG = "RhizoVpnTest";

    private TextView tv;
    private volatile boolean destroyed;
    private Thread pollThread;

    // show the title and start the poll thread
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        tv = new TextView(this);
        tv.setTextSize(32);
        tv.setTextColor(Color.WHITE);
        tv.setPadding(24, 24, 24, 24);
        setContentView(tv);
        setStatusUi("starting", false);

        Intent prepare = VpnService.prepare(this);
        if (prepare != null) {
            Log.i(TAG, "RHIZO_VPN_PREPARE_NEEDED");
            setStatusUi("consent not granted", false);
            return;
        }
        Log.i(TAG, "RHIZO_VPN_PREPARED");
        startService(new Intent(this, VpnTestService.class));

        pollThread = new Thread(new Runnable() {
            public void run() { pollLoop(); }
        }, "rhizo-vpntest-poll");
        pollThread.start();
    }

    // show whether the tunnel is established every 300 ms
    private void pollLoop() {
        while (!destroyed) {
            boolean established = VpnTestService.sEstablished;
            setStatusUi(established ? "tunnel established" : "tunnel not established", established);
            try {
                Thread.sleep(300);
            } catch (InterruptedException e) {
                return;
            }
        }
    }

    // show the status on a green or red background
    private void setStatusUi(final String status, final boolean established) {
        final int bg = established ? Color.rgb(0, 100, 0) : Color.rgb(130, 0, 0);
        runOnUiThread(new Runnable() {
            public void run() {
                tv.setText("RHIZO VPN TEST\n" + status);
                tv.setBackgroundColor(bg);
            }
        });
    }

    // stop the poll thread
    @Override
    protected void onDestroy() {
        destroyed = true;
        if (pollThread != null) pollThread.interrupt();
        super.onDestroy();
    }
}
