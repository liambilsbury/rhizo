package com.rhizo.secureapp;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.WindowManager;
import android.widget.TextView;

// activity with a FLAG_SECURE window and a red label
public class MainActivity extends Activity {
    // set FLAG_SECURE and draw the label
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        TextView t = new TextView(this);
        t.setText("FLAG_SECURE");
        t.setTextSize(48);
        t.setTextColor(Color.RED);
        t.setBackgroundColor(Color.GREEN);
        setContentView(t);
    }
}
