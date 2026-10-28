package com.rhizo.desktop;

import android.util.Log;

// logging calls for desktop-bridge
final class Logs {
    private static final String TAG = "rhizo-desk";

    // forbid instances
    private Logs() {}

    // log an info message
    static void i(String msg) {
        Log.i(TAG, msg);
    }

    // log an error message
    static void e(String msg) {
        Log.e(TAG, msg);
    }

    // log an error message with its throwable
    static void e(String msg, Throwable t) {
        Log.e(TAG, msg, t);
    }
}
