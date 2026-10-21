package com.rhizo.virtualdevice;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

// boot BroadcastReceiver for VirtualDeviceService
public class BootReceiver extends BroadcastReceiver {
    // start the virtual device app service after boot
    @Override
    public void onReceive(Context context, Intent intent) {
        Logs.i("RHIZO_VIRTUAL_DEVICE boot_completed, starting VirtualDeviceService");
        context.startService(new Intent(context, VirtualDeviceService.class));
    }
}
