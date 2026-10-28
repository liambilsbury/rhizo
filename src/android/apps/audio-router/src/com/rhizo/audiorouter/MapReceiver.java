package com.rhizo.audiorouter;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

// BroadcastReceiver for audio map reloads
public class MapReceiver extends BroadcastReceiver {
    // reload the audio map and report the router state as the result
    @Override
    public void onReceive(Context context, Intent intent) {
        RouterApp app = RouterApp.get();
        if (app == null) {
            Log.e(RouterApp.TAG, "MAP received before the router process was up");
            setResultCode(1);
            setResultData("router-not-ready");
            return;
        }
        if (!intent.getBooleanExtra("dump", false)) {
            app.reload();
        }
        String state = app.describe();
        Log.i(RouterApp.TAG, "receiver: " + state);
        setResultCode(0);
        setResultData(state);
    }
}
