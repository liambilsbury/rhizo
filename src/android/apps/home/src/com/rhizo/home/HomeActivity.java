package com.rhizo.home;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Color;
import android.os.Bundle;
import android.util.Log;
import android.view.View;

// black home activity that logs each HOME for rhizo-task-bounds.sh
public final class HomeActivity extends Activity {
    // the log tag rhizo-task-bounds.sh reads
    private static final String TAG = "RhizoHome";
    // set on the home intent started by the home key
    private static final String EXTRA_FROM_HOME_KEY = "android.intent.extra.FROM_HOME_KEY";

    // close-system-dialogs with reason "homekey" marks a home key press on any display
    private static final class HomeKeyReceiver extends BroadcastReceiver {
        // log a close-system-dialogs broadcast sent for the home key
        @Override
        public void onReceive(Context context, Intent intent) {
            if ("homekey".equals(intent.getStringExtra("reason"))) Log.i(TAG, "home key");
        }
    }

    private final BroadcastReceiver homeKey = new HomeKeyReceiver();

    // show a black full-screen view and log home key presses
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        View v = new View(this);
        v.setBackgroundColor(Color.BLACK);
        setContentView(v);
        registerReceiver(homeKey, new IntentFilter(Intent.ACTION_CLOSE_SYSTEM_DIALOGS),
                Context.RECEIVER_NOT_EXPORTED);
        // a home key that created this activity was broadcast before the receiver existed
        if (getIntent().getBooleanExtra(EXTRA_FROM_HOME_KEY, false)) Log.i(TAG, "home key");
    }

    // log a HOME intent
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        Log.i(TAG, "home intent");
    }

    // unregister the home key receiver
    @Override
    protected void onDestroy() {
        unregisterReceiver(homeKey);
        super.onDestroy();
    }
}
