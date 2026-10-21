package com.rhizo.winapp;

import android.app.Activity;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.os.Bundle;
import android.util.Base64;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Display;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.PointerIcon;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.widget.EditText;
import android.widget.FrameLayout;

import java.nio.charset.StandardCharsets;

// activity for windowing and input tests
public class MainActivity extends Activity {
    private static final String TAG = "RhizoWinApp";

    private static final int BAND_HEIGHT = 80;
    private static final int CHECKER_INSET = 16;
    private static final int CHECKER_SIZE = 48;
    private static final int DEFAULT_RGB = 0xFF808080;

    private volatile String lastNonce = "none";

    private DrawView drawView;
    private KeyLoggingEditText editText;

    private int lastWinInfoW = -1, lastWinInfoH = -1, lastWinInfoDisplay = -1, lastWinInfoDensity = -1;

    // build the UI and handle the launch intent
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        buildUi();
        registerLiveReceiver();
        handleIntent(getIntent());
    }

    // log the destroy token
    @Override
    protected void onDestroy() {
        logToken("RHIZO_DESTROYED", "nonce=" + lastNonce);
        super.onDestroy();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleIntent(intent);
    }

    // log the window info after a configuration change
    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        emitWinInfo(false);
    }

    private final android.content.BroadcastReceiver liveReceiver = new android.content.BroadcastReceiver() {
        @Override
        public void onReceive(android.content.Context c, Intent i) {
            String n = i.getStringExtra("nonce");
            if (n != null) lastNonce = n;
            logToken("RHIZO_ALIVE", "nonce=" + lastNonce);
        }
    };

    // register the ping receiver
    private void registerLiveReceiver() {
        android.content.IntentFilter f = new android.content.IntentFilter(getPackageName() + ".PING");
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            registerReceiver(liveReceiver, f, android.content.Context.RECEIVER_EXPORTED);
        } else {
            registerReceiver(liveReceiver, f);
        }
    }

    // build the draw view and text field
    private void buildUi() {
        FrameLayout root = new FrameLayout(this);

        drawView = new DrawView(this);
        root.addView(drawView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        editText = new KeyLoggingEditText(this);
        editText.setFocusable(true);
        editText.setFocusableInTouchMode(true);
        editText.requestFocus();
        editText.setSingleLine(false);
        editText.addTextChangedListener(new TextWatcherAdapter() {
            @Override
            public void afterTextChanged(android.text.Editable s) {
                logToken("RHIZO_TEXT", "nonce=" + lastNonce + " b64=" + b64(s.toString().getBytes(StandardCharsets.UTF_8)));
            }
        });
        FrameLayout.LayoutParams editParams = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        editParams.gravity = android.view.Gravity.BOTTOM;
        root.addView(editText, editParams);

        root.getViewTreeObserver().addOnGlobalLayoutListener(new ViewTreeObserver.OnGlobalLayoutListener() {
            @Override
            public void onGlobalLayout() {
                emitWinInfo(false);
            }
        });

        setContentView(root);
        editText.requestFocus();
    }

    // remember the nonce and run the intent's command
    private void handleIntent(Intent intent) {
        if (intent == null) return;
        String nonce = intent.getStringExtra("nonce");
        if (nonce != null) lastNonce = nonce;
        String cmd = intent.getStringExtra("cmd");
        if (cmd == null) return;
        try {
            runCommand(cmd, intent);
        } catch (Exception e) {
            Log.e(TAG, "RHIZO_CMD_FAILED cmd=" + cmd + " exception=" + e, e);
        }
    }

    // run the command from the intent
    private void runCommand(String cmd, Intent intent) {
        switch (cmd) {
            case "ping":
                logToken("RHIZO_ALIVE", "nonce=" + lastNonce);
                break;
            case "win_info":
                emitWinInfo(true);
                break;
            case "focus_state":
                boolean wf = drawView != null && drawView.hasWindowFocus();
                boolean vf = editText != null && editText.hasFocus();
                boolean ic = editText != null && editText.hasWindowFocus()
                        && editText.onCheckIsTextEditor();
                logToken("RHIZO_FOCUS", "nonce=" + lastNonce + " focused=" + wf
                        + " field=" + vf + " editor=" + ic);
                break;
            case "set_icon":
                doSetIcon(intent.getStringExtra("icon"));
                break;
            case "set_color":
                doSetColor(intent.getStringExtra("rgb"));
                break;
            case "clear_text":
                editText.setText("");
                break;
            default:
                Log.e(TAG, "RHIZO_UNKNOWN_CMD cmd=" + cmd);
        }
    }

    // log the window size and display info
    private void emitWinInfo(boolean force) {
        View root = drawView != null ? (View) drawView.getParent() : null;
        if (root == null) return;
        int w = root.getWidth();
        int h = root.getHeight();
        if (w <= 0 || h <= 0) return;

        Display display = getWindowManager().getDefaultDisplay();
        int displayId = display.getDisplayId();
        DisplayMetrics dm = getResources().getDisplayMetrics();
        DisplayMetrics realDm = new DisplayMetrics();
        display.getRealMetrics(realDm);

        if (!force && w == lastWinInfoW && h == lastWinInfoH
                && displayId == lastWinInfoDisplay && dm.densityDpi == lastWinInfoDensity) {
            return;
        }
        lastWinInfoW = w;
        lastWinInfoH = h;
        lastWinInfoDisplay = displayId;
        lastWinInfoDensity = dm.densityDpi;

        logToken("RHIZO_WIN_INFO", "nonce=" + lastNonce + " w=" + w + " h=" + h + " display=" + displayId
                + " densityDpi=" + dm.densityDpi + " density=" + dm.density
                + " realw=" + realDm.widthPixels + " realh=" + realDm.heightPixels);
    }

    // set the pointer icon by name
    private void doSetIcon(String name) {
        int type = iconTypeFromName(name);
        PointerIcon icon = PointerIcon.getSystemIcon(this, type);
        drawView.setPointerIcon(icon);
        PointerIcon applied = drawView.getPointerIcon();
        logToken("RHIZO_ICON", "nonce=" + lastNonce + " requested=" + (name != null ? name : "")
                + " appliedName=" + describeIcon(applied)
                + " appliedMatchesRequested=" + icon.equals(applied));
    }

    // set the band color from a hex value
    private void doSetColor(String hex) {
        int rgb;
        try {
            rgb = 0xFF000000 | (Integer.parseInt(hex, 16) & 0x00FFFFFF);
        } catch (Exception e) {
            Log.e(TAG, "RHIZO_CMD_FAILED cmd=set_color bad hex=" + hex, e);
            return;
        }
        drawView.setColorAndInvalidate(rgb);
    }

    // return the pointer icon type for a name
    private static int iconTypeFromName(String name) {
        if (name == null) return PointerIcon.TYPE_ARROW;
        switch (name) {
            case "ARROW": return PointerIcon.TYPE_ARROW;
            case "TEXT": return PointerIcon.TYPE_TEXT;
            case "CROSSHAIR": return PointerIcon.TYPE_CROSSHAIR;
            case "HAND": return PointerIcon.TYPE_HAND;
            default: return PointerIcon.TYPE_ARROW;
        }
    }

    private PointerIcon[] namedSystemIcons;
    private static final String[] ICON_NAMES = {"ARROW", "TEXT", "CROSSHAIR", "HAND"};

    // return the name of a system pointer icon
    private String describeIcon(PointerIcon icon) {
        if (icon == null) return "NULL";
        if (namedSystemIcons == null) {
            namedSystemIcons = new PointerIcon[ICON_NAMES.length];
            for (int i = 0; i < ICON_NAMES.length; i++) {
                namedSystemIcons[i] = PointerIcon.getSystemIcon(this, iconTypeFromName(ICON_NAMES[i]));
            }
        }
        for (int i = 0; i < ICON_NAMES.length; i++) {
            if (icon.equals(namedSystemIcons[i])) return ICON_NAMES[i];
        }
        return "UNKNOWN";
    }

    // encode bytes as base64 without line breaks
    private static String b64(byte[] bytes) {
        return Base64.encodeToString(bytes, Base64.NO_WRAP);
    }

    // write the token and its detail to the log
    private static void logToken(String token, String rest) {
        Log.i(TAG, rest.isEmpty() ? token : token + " " + rest);
    }

    // TextWatcher adapter for afterTextChanged
    private abstract static class TextWatcherAdapter implements android.text.TextWatcher {
        @Override
        public void beforeTextChanged(CharSequence s, int start, int count, int after) {}

        @Override
        public void onTextChanged(CharSequence s, int start, int before, int count) {}
    }

    // EditText logging key events
    private final class KeyLoggingEditText extends EditText {
        KeyLoggingEditText(android.content.Context context) {
            super(context);
        }

        @Override
        public boolean onKeyDown(int keyCode, KeyEvent event) {
            logKeyEvent("down", event);
            return super.onKeyDown(keyCode, event);
        }

        @Override
        public boolean onKeyUp(int keyCode, KeyEvent event) {
            logKeyEvent("up", event);
            return super.onKeyUp(keyCode, event);
        }

        private void logKeyEvent(String phase, KeyEvent event) {
            int uni = event.getUnicodeChar(event.getMetaState());
            byte[] uniBytes;
            if (uni == 0) {
                uniBytes = new byte[0];
            } else {
                try {
                    uniBytes = new String(Character.toChars(uni)).getBytes(StandardCharsets.UTF_8);
                } catch (IllegalArgumentException e) {
                    uniBytes = new byte[0];
                }
            }
            logToken("RHIZO_KEY", "nonce=" + lastNonce + " event=" + phase
                    + " keyCode=" + event.getKeyCode()
                    + " scanCode=" + event.getScanCode()
                    + " metaState=" + event.getMetaState()
                    + " unicodeB64=" + b64(uniBytes));
        }
    }

    // band and checkerboard view
    private final class DrawView extends View {
        private int colorRgb = DEFAULT_RGB;
        private int lastReportedColor = -1;
        private final Paint bandPaint = new Paint();
        private final Paint checkerPaint = new Paint();
        private final Paint textPaint = new Paint();
        private final Bitmap checkerBitmap;

        private float accumV = 0f, accumH = 0f;

        DrawView(android.content.Context context) {
            super(context);
            checkerPaint.setFilterBitmap(false);
            checkerPaint.setAntiAlias(false);
            textPaint.setColor(Color.WHITE);
            textPaint.setTextSize(20f);
            textPaint.setAntiAlias(true);

            checkerBitmap = Bitmap.createBitmap(CHECKER_SIZE, CHECKER_SIZE, Bitmap.Config.ARGB_8888);
            for (int y = 0; y < CHECKER_SIZE; y++) {
                for (int x = 0; x < CHECKER_SIZE; x++) {
                    checkerBitmap.setPixel(x, y, ((x + y) % 2 == 0) ? Color.BLACK : Color.WHITE);
                }
            }
        }

        private boolean touchDrawPending = false;

        void setColorAndInvalidate(int rgb) {
            colorRgb = rgb;
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            canvas.drawColor(0xFF202020);
            bandPaint.setColor(colorRgb);
            canvas.drawRect(0, 0, getWidth(), BAND_HEIGHT, bandPaint);

            int cx = CHECKER_INSET;
            int cy = BAND_HEIGHT + CHECKER_INSET;
            Rect dst = new Rect(cx, cy, cx + CHECKER_SIZE, cy + CHECKER_SIZE);
            canvas.drawBitmap(checkerBitmap, null, dst, checkerPaint);
            canvas.drawText("RHIZO WINAPP " + lastNonce, cx, cy + CHECKER_SIZE + 24, textPaint);

            if (touchDrawPending) {
                touchDrawPending = false;
                logToken("RHIZO_TOUCH_DRAW", "nonce=" + lastNonce);
            }

            if (colorRgb != lastReportedColor) {
                lastReportedColor = colorRgb;
                int[] loc = new int[2];
                getLocationInWindow(loc);
                logToken("RHIZO_DRAW", "nonce=" + lastNonce + " rgb=" + String.format("%06X", colorRgb & 0xFFFFFF)
                        + " rectX=" + (loc[0] + cx) + " rectY=" + (loc[1] + cy)
                        + " rectW=" + CHECKER_SIZE + " rectH=" + CHECKER_SIZE);
            }
        }

        @Override
        public PointerIcon onResolvePointerIcon(MotionEvent event, int pointerIndex) {
            PointerIcon icon = super.onResolvePointerIcon(event, pointerIndex);
            logToken("RHIZO_ICON_RESOLVE", "nonce=" + lastNonce + " name=" + describeIcon(icon));
            return icon;
        }

        @Override
        public void onWindowFocusChanged(boolean hasFocus) {
            super.onWindowFocusChanged(hasFocus);
            logToken("RHIZO_FOCUS", "nonce=" + lastNonce + " focused=" + hasFocus);
        }

        @Override
        public boolean onTouchEvent(MotionEvent event) {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
                touchDrawPending = true;
                invalidate();
            }
            emitPointer(event, "touch");
            return true;
        }

        @Override
        public boolean onGenericMotionEvent(MotionEvent event) {
            if (event.getAction() == MotionEvent.ACTION_SCROLL) {
                float v = event.getAxisValue(MotionEvent.AXIS_VSCROLL);
                float h = event.getAxisValue(MotionEvent.AXIS_HSCROLL);
                accumV += v;
                accumH += h;
                logToken("RHIZO_SCROLL", "nonce=" + lastNonce + " source=" + event.getSource()
                        + " vscroll=" + v + " hscroll=" + h
                        + " accumV=" + accumV + " accumH=" + accumH);
                return true;
            }
            emitPointer(event, "generic");
            return true;
        }

        private void emitPointer(MotionEvent event, String via) {
            int action = event.getActionMasked();
            logToken("RHIZO_POINTER", "nonce=" + lastNonce + " via=" + via
                    + " action=" + action + " actionName=" + MotionEvent.actionToString(action)
                    + " x=" + event.getX() + " y=" + event.getY()
                    + " rawX=" + event.getRawX() + " rawY=" + event.getRawY()
                    + " source=" + event.getSource());
        }
    }
}
