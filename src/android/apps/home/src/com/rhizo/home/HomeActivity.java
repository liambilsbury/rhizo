package com.rhizo.home;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.View;

// home activity with a black view
public final class HomeActivity extends Activity {
    // show a black full-screen view
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        View v = new View(this);
        v.setBackgroundColor(Color.BLACK);
        setContentView(v);
    }
}
