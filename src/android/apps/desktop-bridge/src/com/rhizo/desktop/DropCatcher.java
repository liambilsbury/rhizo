package com.rhizo.desktop;

import android.content.ClipData;
import android.content.ClipDescription;
import android.content.Context;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Base64;
import android.view.Display;
import android.view.DragEvent;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewTreeObserver;
import android.view.WindowManager;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executor;
import java.util.function.Consumer;

// overlay pads for drag and drop
final class DropCatcher {
    private static final int PAD_SIZE_PX = 16;
    private static final int CORNER_MARGIN_PX = 8;
    private static final float INPUT_MIN_ALPHA = 0.01f;
    private static final float INPUT_MIN_FRACTION = 0.5f;
    private static final int INPUT_STABLE_MS = 1;

    private enum Mode { ARMED, WATCHING }

    // overlay pad for a display
    private static final class Pad {
        final WindowManager wm;
        final View view;
        Mode mode;
        boolean onInput;
        boolean watchAsked;
        Consumer<Boolean> inputListener;

        Pad(WindowManager wm, View view, Mode mode) {
            this.wm = wm;
            this.view = view;
            this.mode = mode;
        }
    }

    private static final Object sLock = new Object();
    private static final Map<Integer, Pad> sPads = new HashMap<>();

    // forbid instances
    private DropCatcher() {}

    // stage the dropped payload and show a pad
    static void handleDrop(final Context context, JSONObject obj) {
        String mime = obj.optString("mime", null);
        String name = obj.optString("name", null);
        final int display = obj.optInt("display", -1);
        if (mime == null || name == null || display < 0) {
            Logs.e("drop missing mime, name or display");
            return;
        }
        byte[] bytes;
        try {
            bytes = Base64.decode(obj.getString("b64"), Base64.NO_WRAP);
        } catch (JSONException | IllegalArgumentException e) {
            Logs.e("drop with unreadable payload", e);
            return;
        }
        final Uri uri;
        try {
            uri = PasteStore.write(context, bytes, mime, "drop_", name);
        } catch (IOException e) {
            Logs.e("cannot stage dropped file", e);
            return;
        }
        Logs.i("RHIZO_DROP_STAGED display=" + display + " name=" + name + " mime=" + mime);
        final String finalMime = mime;
        final String finalName = name;
        new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override
            public void run() {
                showPad(context, display, Mode.ARMED, uri, finalMime, finalName);
            }
        });
    }

    // show the drag watch pad
    static void handleDragwatch(final Context context, JSONObject obj) {
        final int display = obj.optInt("display", -1);
        if (display < 0) {
            Logs.e("dragwatch missing display");
            return;
        }
        new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override
            public void run() {
                Pad existing;
                synchronized (sLock) {
                    existing = sPads.get(display);
                }
                if (existing != null && existing.view.isAttachedToWindow()) {
                    if (!existing.onInput) {
                        existing.watchAsked = true;
                        return;
                    }
                    announceReady(existing.view, Mode.WATCHING, display,
                            CORNER_MARGIN_PX + PAD_SIZE_PX / 2,
                            CORNER_MARGIN_PX + PAD_SIZE_PX / 2,
                            context.getApplicationContext());
                    return;
                }
                showPad(context, display, Mode.WATCHING, null, null, null);
            }
        });
    }

    // remove all overlay pads
    static void cancel() {
        new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override
            public void run() {
                List<Integer> displays;
                synchronized (sLock) {
                    displays = new ArrayList<>(sPads.keySet());
                }
                for (int display : displays) {
                    removeOverlay(display);
                }
            }
        });
    }

    // add an overlay pad to a display
    private static void showPad(final Context context, final int displayId, final Mode mode,
            final Uri uri, final String mime, final String name) {
        removeOverlay(displayId);
        Display target = context.getSystemService(DisplayManager.class).getDisplay(displayId);
        if (target == null) {
            reportError(context, displayId, mode, "no display " + displayId);
            return;
        }
        Context displayContext = context.createDisplayContext(target);
        WindowManager wm = displayContext.getSystemService(WindowManager.class);
        final View pad = new View(displayContext);
        pad.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View v, MotionEvent event) {
                if (mode != Mode.ARMED || event.getActionMasked() != MotionEvent.ACTION_DOWN) {
                    return false;
                }
                armDrag(context, v, displayId, uri, mime, name);
                return true;
            }
        });
        pad.setOnDragListener(new View.OnDragListener() {
            @Override
            public boolean onDrag(View v, DragEvent event) {
                return onPadDrag(context, displayId, event);
            }
        });

        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                PAD_SIZE_PX, PAD_SIZE_PX,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.START;
        lp.x = CORNER_MARGIN_PX;
        lp.y = CORNER_MARGIN_PX;

        try {
            wm.addView(pad, lp);
        } catch (SecurityException | WindowManager.BadTokenException e) {
            reportError(context, displayId, mode, String.valueOf(e));
            return;
        }

        final Pad entry = new Pad(wm, pad, mode);
        synchronized (sLock) {
            sPads.put(displayId, entry);
        }

        final Context appContext = context.getApplicationContext();
        if (Build.VERSION.SDK_INT < 35) {
            announceOnFirstDraw(entry, displayId, appContext);
            return;
        }
        pad.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener() {
            @Override
            public void onViewAttachedToWindow(View v) {
                v.removeOnAttachStateChangeListener(this);
                announceOnInput(entry, displayId, appContext);
            }

            @Override
            public void onViewDetachedFromWindow(View v) {}
        });
    }

    // report the pad ready once its window takes input
    private static void announceOnInput(final Pad entry, final int displayId, final Context appContext) {
        Consumer<Boolean> listener = new Consumer<Boolean>() {
            @Override
            public void accept(Boolean presented) {
                if (!presented || entry.onInput) {
                    return;
                }
                stopInputWait(entry);
                padOnInput(entry, displayId, appContext);
            }
        };
        try {
            Class<?> thresholdsClass = Class.forName("android.window.TrustedPresentationThresholds");
            Object thresholds = thresholdsClass.getConstructor(float.class, float.class, int.class)
                    .newInstance(INPUT_MIN_ALPHA, INPUT_MIN_FRACTION, INPUT_STABLE_MS);
            WindowManager.class.getMethod("registerTrustedPresentationListener",
                    IBinder.class, thresholdsClass, Executor.class, Consumer.class)
                    .invoke(entry.wm, entry.view.getWindowToken(), thresholds,
                            appContext.getMainExecutor(), listener);
            entry.inputListener = listener;
        } catch (ReflectiveOperationException | RuntimeException e) {
            Logs.e("cannot watch the pad's input state on display " + displayId
                    + "; using its first frame", e);
            announceOnFirstDraw(entry, displayId, appContext);
        }
    }

    // stop watching the pad window's input state
    private static void stopInputWait(Pad entry) {
        Consumer<Boolean> listener = entry.inputListener;
        entry.inputListener = null;
        if (listener == null) {
            return;
        }
        try {
            WindowManager.class.getMethod("unregisterTrustedPresentationListener", Consumer.class)
                    .invoke(entry.wm, listener);
        } catch (ReflectiveOperationException | RuntimeException e) {
            Logs.e("cannot stop watching the pad window's input state", e);
        }
    }

    // report the pad ready on its first frame
    private static void announceOnFirstDraw(final Pad entry, final int displayId, final Context appContext) {
        final View pad = entry.view;
        pad.getViewTreeObserver().addOnDrawListener(
                new ViewTreeObserver.OnDrawListener() {
                    @Override
                    public void onDraw() {
                        final ViewTreeObserver.OnDrawListener self = this;
                        pad.post(new Runnable() {
                            @Override
                            public void run() {
                                pad.getViewTreeObserver().removeOnDrawListener(self);
                                padOnInput(entry, displayId, appContext);
                            }
                        });
                    }
                });
    }

    // mark the pad ready and report it in its current mode
    private static void padOnInput(Pad entry, int displayId, Context appContext) {
        if (entry.onInput) {
            return;
        }
        entry.onInput = true;
        Logs.i("RHIZO_PAD_ON_INPUT display=" + displayId + " mode=" + entry.mode);
        final int center = CORNER_MARGIN_PX + PAD_SIZE_PX / 2;
        announceReady(entry.view, entry.mode, displayId, center, center, appContext);
        if (entry.watchAsked && entry.mode != Mode.WATCHING) {
            announceReady(entry.view, Mode.WATCHING, displayId, center, center, appContext);
        }
        entry.watchAsked = false;
    }

    // send the pad position to the host
    private static void announceReady(final View pad, final Mode mode, final int displayId,
            final int centerX, final int centerY, final Context appContext) {
                        boolean current;
                        synchronized (sLock) {
                            Pad now = sPads.get(displayId);
                            current = now != null && now.view == pad;
                        }
                        if (!current) {
                            return;
                        }
                        int[] at = new int[2];
                        pad.getLocationOnScreen(at);
                        int x = at[0] + pad.getWidth() / 2;
                        int y = at[1] + pad.getHeight() / 2;
                        if (pad.getWidth() == 0 || pad.getHeight() == 0) {
                            x = centerX;
                            y = centerY;
                        }
                        String type = mode == Mode.WATCHING ? "dragwatch_ready" : "drop_pad";
                        Logs.i((mode == Mode.WATCHING ? "RHIZO_DRAGWATCH_READY" : "RHIZO_DROP_PAD_SHOWN")
                                + " display=" + displayId + " x=" + x + " y=" + y);
                        JSONObject reply = new JSONObject();
                        try {
                            reply.put("t", type);
                            reply.put("display", displayId);
                            reply.put("x", x);
                            reply.put("y", y);
                        } catch (JSONException e) {
                            Logs.e("cannot build " + type + " payload", e);
                            return;
                        }
                        BridgeService.enqueue(appContext, reply);
    }

    // start a global drag of the uri and report that it is armed
    private static void armDrag(Context context, View v, int displayId, Uri uri, String mime, String name) {
        ClipData clip = new ClipData(name, new String[] {mime}, new ClipData.Item(uri));
        int flags = View.DRAG_FLAG_GLOBAL | View.DRAG_FLAG_GLOBAL_URI_READ;
        if (!v.startDragAndDrop(clip, new View.DragShadowBuilder(v), null, flags)) {
            reportError(context, displayId, Mode.ARMED, "startDragAndDrop refused");
            return;
        }
        Logs.i("RHIZO_DRAG_ARMED");
        JSONObject obj = new JSONObject();
        try {
            obj.put("t", "drag_armed");
        } catch (JSONException e) {
            Logs.e("cannot build drag_armed payload", e);
            return;
        }
        BridgeService.enqueue(context, obj);
    }

    // report drag events for a display pad
    private static boolean onPadDrag(Context context, int displayId, DragEvent event) {
        Mode mode;
        synchronized (sLock) {
            Pad pad = sPads.get(displayId);
            mode = pad != null ? pad.mode : Mode.WATCHING;
        }
        switch (event.getAction()) {
            case DragEvent.ACTION_DRAG_STARTED:
                if (mode == Mode.WATCHING) {
                    reportDragStarted(context, displayId, event.getClipDescription());
                }
                return true;
            case DragEvent.ACTION_DROP:
                if (mode == Mode.WATCHING) {
                    reportDragData(context, displayId, event);
                }
                return true;
            case DragEvent.ACTION_DRAG_ENDED:
                Logs.i("RHIZO_DRAG_ENDED result=" + event.getResult() + " display=" + displayId);
                sendDragEnded(context, displayId, event.getResult());
                synchronized (sLock) {
                    Pad pad = sPads.get(displayId);
                    if (pad != null) {
                        pad.mode = Mode.WATCHING;
                    }
                }
                return true;
            default:
                return true;
        }
    }

    // log and send the mime types of a started drag
    private static void reportDragStarted(Context context, int displayId, ClipDescription desc) {
        JSONArray mimes = new JSONArray();
        StringBuilder log = new StringBuilder();
        int count = desc != null ? desc.getMimeTypeCount() : 0;
        for (int i = 0; i < count; i++) {
            String m = desc.getMimeType(i);
            mimes.put(m);
            if (i > 0) {
                log.append(',');
            }
            log.append(m);
        }
        Logs.i("RHIZO_DRAGOUT_STARTED mimes=" + log + " display=" + displayId);
        JSONObject obj = new JSONObject();
        try {
            obj.put("t", "drag_started");
            obj.put("mimes", mimes);
            obj.put("display", displayId);
        } catch (JSONException e) {
            Logs.e("cannot build drag_started payload", e);
            return;
        }
        BridgeService.enqueue(context, obj);
    }

    // send the dragged item to the host
    private static void reportDragData(Context context, int displayId, DragEvent event) {
        ClipData clip = event.getClipData();
        if (clip == null || clip.getItemCount() == 0) {
            reportDragDataError(context, "drop carried no clip data");
            return;
        }
        ClipDescription desc = event.getClipDescription();
        String mime = desc != null && desc.getMimeTypeCount() > 0 ? desc.getMimeType(0) : "application/octet-stream";
        ClipData.Item item = clip.getItemAt(0);
        byte[] bytes;
        if (item.getText() != null) {
            bytes = item.getText().toString().getBytes(StandardCharsets.UTF_8);
        } else if (item.getUri() != null) {
            reportDragDataError(context, "no activity context to request drag permissions for " + item.getUri());
            return;
        } else {
            reportDragDataError(context, "clip item carries neither text nor a uri");
            return;
        }
        Logs.i("RHIZO_DRAGOUT_DATA mime=" + mime + " bytes=" + bytes.length + " display=" + displayId);
        JSONObject obj = new JSONObject();
        try {
            obj.put("t", "drag_data");
            obj.put("mime", mime);
            obj.put("b64", Base64.encodeToString(bytes, Base64.NO_WRAP));
            obj.put("display", displayId);
        } catch (JSONException e) {
            Logs.e("cannot build drag_data payload", e);
            return;
        }
        BridgeService.enqueue(context, obj);
    }

    // log and send why drag data is unavailable
    private static void reportDragDataError(Context context, String reason) {
        Logs.e("drag data unavailable: " + reason);
        JSONObject obj = new JSONObject();
        try {
            obj.put("t", "drag_data_error");
            obj.put("reason", reason);
        } catch (JSONException e) {
            Logs.e("cannot build drag_data_error payload", e);
            return;
        }
        BridgeService.enqueue(context, obj);
    }

    // send the result of a finished drag
    private static void sendDragEnded(Context context, int displayId, boolean result) {
        JSONObject obj = new JSONObject();
        try {
            obj.put("t", "drag_ended");
            obj.put("result", result);
            obj.put("display", displayId);
        } catch (JSONException e) {
            Logs.e("cannot build drag_ended payload", e);
            return;
        }
        BridgeService.enqueue(context, obj);
    }

    // log and send a drag watch or drop error
    private static void reportError(Context context, int displayId, Mode mode, String reason) {
        String type = mode == Mode.WATCHING ? "dragwatch_error" : "drop_error";
        Logs.e(type + " for display " + displayId + ": " + reason);
        JSONObject obj = new JSONObject();
        try {
            obj.put("t", type);
            obj.put("display", displayId);
            obj.put("reason", reason);
        } catch (JSONException e) {
            Logs.e("cannot build " + type + " payload", e);
            return;
        }
        BridgeService.enqueue(context, obj);
    }

    // remove the overlay pad from a display
    private static void removeOverlay(int displayId) {
        Pad pad;
        synchronized (sLock) {
            pad = sPads.remove(displayId);
        }
        if (pad == null) {
            return;
        }
        stopInputWait(pad);
        try {
            pad.wm.removeView(pad.view);
        } catch (IllegalArgumentException e) {
            Logs.i("pad on display " + displayId + " was already gone: " + e.getMessage());
        }
    }
}
