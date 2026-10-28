package com.rhizo.networklocation;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

import java.io.FileDescriptor;
import java.io.PrintWriter;

// the service LocationManagerService binds as the network provider
public final class NetworkLocationService extends Service {
    private NetworkLocationProvider provider;

    @Override
    public IBinder onBind(Intent intent) {
        if (provider == null) {
            provider = new NetworkLocationProvider(this);
        }
        return provider.getBinder();
    }

    @Override
    public void onDestroy() {
        if (provider != null) {
            provider.stop();
            provider = null;
        }
    }

    @Override
    protected void dump(FileDescriptor fd, PrintWriter pw, String[] args) {
        if (provider != null) {
            provider.dump(pw);
        } else {
            pw.println("unbound");
        }
    }
}
