package com.rhizo.audiorouter;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

// BroadcastReceiver for audio map reloads
public class MapReceiver extends BroadcastReceiver {
    // reload the audio map
    @Override
    public void onReceive(Context context, Intent intent) {
        RouterApp app = RouterApp.get();
        if (app == null) {
            Log.e(RouterApp.TAG, "RouterApp.get() returned null");
            setResultCode(1);
            setResultData("router-not-ready");
            return;
        }
        if (!intent.getBooleanExtra("dump", false)) {
            app.reload();
        }
        String state = app.describe();
        Log.i(RouterApp.TAG, "setResultData " + state);
        setResultCode(0);
        setResultData(state);
    }
}
