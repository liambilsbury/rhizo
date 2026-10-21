package com.rhizo.nettest;

import android.app.Activity;
import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.graphics.Color;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.URL;

// activity for network system tests
public class MainActivity extends Activity {
    private static final String TAG = "RhizoNetTest";
    private static final String HOST = "rhizo-test.internal";
    private static final int PORT = 80;
    private static final String PATH = "/nettest";
    private static final String MARKER = "RHIZO-NET-OK";

    private TextView tv;

    // run the probe for the mode extra
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        tv = new TextView(this);
        tv.setTextSize(32);
        tv.setTextColor(Color.WHITE);
        tv.setPadding(24, 24, 24, 24);
        tv.setText("RHIZO NET TEST\nconnecting...");
        setContentView(tv);

        if ("reportbad".equals(getIntent().getStringExtra("mode"))) {
            ConnectivityManager cm =
                    (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
            Network n = cm == null ? null : cm.getActiveNetwork();
            if (n == null) {
                Log.e(TAG, "RHIZO_REPORT_FAIL reason=no_active_network");
                setResultUi("no active network", false);
            } else {
                cm.reportNetworkConnectivity(n, false);
                Log.i(TAG, "RHIZO_REPORT_SENT network=" + n);
                setResultUi("reported " + n + " as not working", true);
            }
            return;
        }
        if ("nsd".equals(getIntent().getStringExtra("mode"))) {
            new NsdProbe(this, new NsdProbe.Callback() {
                public void onResult(String text, boolean ok) { setResultUi(text, ok); }
            }).start();
            return;
        }
        new Thread(new Runnable() {
            public void run() { runProbe(); }
        }, "rhizo-nettest-probe").start();
    }

    // fetch a URL and show the result
    private void runProbe() {
        StringBuilder ui = new StringBuilder();
        boolean ok = false;
        String path = getIntent().getStringExtra("path");
        if (path == null || path.length() == 0) path = PATH;
        String marker = getIntent().getStringExtra("marker");
        if (marker == null || marker.length() == 0) marker = MARKER;
        String host = getIntent().getStringExtra("host");
        if (host == null || host.length() == 0) host = HOST;
        String override = getIntent().getStringExtra("url");
        int expect = 200;
        String expectStr = getIntent().getStringExtra("expect");
        if (expectStr != null && expectStr.length() > 0) {
            try { expect = Integer.parseInt(expectStr.trim()); } catch (Exception ignored) {}
        }
        try {
            String target;
            String resolved;
            if (override != null && override.length() > 0) {
                target = override;
                String oh = new URL(override).getHost();
                String r;
                try {
                    r = InetAddress.getByName(oh).getHostAddress();
                } catch (Exception unresolved) {
                    r = "proxied";
                }
                resolved = r;
                ui.append("target ").append(override).append(" -> ").append(r).append('\n');
            } else {
                InetAddress addr = InetAddress.getByName(host);
                resolved = addr.getHostAddress();
                ui.append("resolved ").append(host).append(" -> ").append(resolved).append('\n');
                target = "http://" + host + ":" + PORT + path;
            }

            URL url = new URL(target);
            HttpURLConnection c = (HttpURLConnection) url.openConnection();
            c.setConnectTimeout(8000);
            c.setReadTimeout(30000);
            int code = c.getResponseCode();
            long bytes = 0;
            byte[] buf = new byte[16384];
            StringBuilder head = new StringBuilder();
            InputStream in = c.getInputStream();
            try {
                int n;
                while ((n = in.read(buf)) > 0) {
                    bytes += n;
                    if (head.length() < 512) {
                        head.append(new String(buf, 0, Math.min(n, 512), "UTF-8"));
                    }
                }
            } finally {
                in.close();
            }
            String body = head.toString();
            ui.append("HTTP ").append(code).append(" bytes=").append(bytes).append('\n').append(body);
            ok = code == expect && ("NONE".equals(marker) || body.contains(marker));
            Log.i(TAG, (ok ? "RHIZO_NETTEST_APP_OK " : "RHIZO_NETTEST_APP_FAIL ")
                    + "resolved=" + resolved + " code=" + code
                    + " bytes=" + bytes + " path=" + path + " target=" + target);
        } catch (Exception e) {
            Log.e(TAG, "RHIZO_NETTEST_APP_FAIL exception=" + e, e);
            ui.append("FAILED: ").append(e);
        }
        setResultUi(ui.toString(), ok);
    }

    // show the text on a green or red background
    private void setResultUi(final String text, final boolean ok) {
        final int bg = ok ? Color.rgb(0, 100, 0) : Color.rgb(130, 0, 0);
        runOnUiThread(new Runnable() {
            public void run() {
                tv.setText(text);
                tv.setBackgroundColor(bg);
            }
        });
    }
}
