package com.rhizo.nettest;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.Socket;

public class NsdProbe {
    private static final String TAG = "RhizoNetTest";
    private static final String SERVICE_TYPE = "_rhizotest._tcp.";

    private final NsdManager nsd;
    private final Callback done;

    public interface Callback {
        void onResult(String text, boolean ok);
    }

    // create the probe from the NSD service
    public NsdProbe(Context ctx, Callback done) {
        this.nsd = (NsdManager) ctx.getSystemService(Context.NSD_SERVICE);
        this.done = done;
    }

    // start discovering services of the probe's type
    public void start() {
        if (nsd == null) {
            Log.e(TAG, "RHIZO_NSD_FAIL reason=no_nsd_service");
            done.onResult("no NsdManager", false);
            return;
        }
        Log.i(TAG, "RHIZO_NSD_START type=" + SERVICE_TYPE);
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery);
    }

    private final NsdManager.DiscoveryListener discovery = new NsdManager.DiscoveryListener() {
        public void onDiscoveryStarted(String type) {
            Log.i(TAG, "RHIZO_NSD_DISCOVERY_STARTED type=" + type);
        }

        public void onServiceFound(NsdServiceInfo info) {
            Log.i(TAG, "RHIZO_NSD_FOUND name=" + info.getServiceName()
                    + " type=" + info.getServiceType());
            nsd.resolveService(info, new NsdManager.ResolveListener() {
                public void onResolveFailed(NsdServiceInfo i, int code) {
                    Log.e(TAG, "RHIZO_NSD_FAIL reason=resolve_failed code=" + code
                            + " name=" + i.getServiceName());
                    done.onResult("resolve failed " + code, false);
                }

                public void onServiceResolved(NsdServiceInfo i) {
                    String host = i.getHost() == null ? "" : i.getHost().getHostAddress();
                    Log.i(TAG, "RHIZO_NSD_RESOLVED name=" + i.getServiceName()
                            + " host=" + host + " port=" + i.getPort());
                    connect(host, i.getPort());
                }
            });
        }

        public void onServiceLost(NsdServiceInfo info) {
            Log.i(TAG, "RHIZO_NSD_LOST name=" + info.getServiceName());
        }

        public void onDiscoveryStopped(String type) { }

        public void onStartDiscoveryFailed(String type, int code) {
            Log.e(TAG, "RHIZO_NSD_FAIL reason=start_discovery_failed code=" + code);
            done.onResult("discovery failed " + code, false);
        }

        public void onStopDiscoveryFailed(String type, int code) { }
    };

    // connect to the discovered host and port
    private void connect(final String host, final int port) {
        new Thread(new Runnable() {
            public void run() {
                Socket s = new Socket();
                try {
                    s.connect(new InetSocketAddress(host, port), 8000);
                    s.setSoTimeout(8000);
                    InputStream in = s.getInputStream();
                    ByteArrayOutputStream out = new ByteArrayOutputStream();
                    byte[] buf = new byte[256];
                    int n;
                    while ((n = in.read(buf)) > 0 && out.size() < 4096) out.write(buf, 0, n);
                    String body = out.toString("UTF-8").trim();
                    boolean ok = body.contains("RHIZO-LAN-OK");
                    Log.i(TAG, (ok ? "RHIZO_NSD_CONNECT " : "RHIZO_NSD_FAIL reason=bad_body ")
                            + "host=" + host + " port=" + port + " body=" + body);
                    done.onResult("discovered " + host + ":" + port + "\n" + body, ok);
                } catch (Exception e) {
                    Log.e(TAG, "RHIZO_NSD_FAIL reason=connect host=" + host
                            + " port=" + port + " error=" + e);
                    done.onResult("connect failed: " + e, false);
                } finally {
                    try { s.close(); } catch (Exception ignored) { }
                }
            }
        }, "rhizo-nsd-connect").start();
    }
}
