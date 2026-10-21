package com.rhizo.desktop;

import android.app.Notification;
import android.app.PendingIntent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.Icon;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import android.util.Base64;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

// notification listener for host mirroring
public class NotifListener extends NotificationListenerService {
    private static final int FALLBACK_ICON_PX = 128;

    private static volatile NotifListener sInstance;

    private final Map<String, StatusBarNotification> mActive = new ConcurrentHashMap<>();

    // record the running listener instance
    @Override
    public void onCreate() {
        super.onCreate();
        sInstance = this;
    }

    // start the bridge service when the listener connects
    @Override
    public void onListenerConnected() {
        super.onListenerConnected();
        BridgeService.startIfMinted(this, "listener");
    }

    // clear the running listener instance
    @Override
    public void onDestroy() {
        sInstance = null;
        super.onDestroy();
    }

    // run a host action on a notification
    static boolean dispatch(String key, boolean close) {
        NotifListener live = sInstance;
        if (live == null) {
            return false;
        }
        live.onHostAction(key, close);
        return true;
    }

    // send the notification to BridgeService
    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        mActive.put(sbn.getKey(), sbn);
        Notification n = sbn.getNotification();
        JSONObject obj = new JSONObject();
        try {
            obj.put("t", "notify");
            obj.put("key", sbn.getKey());
            obj.put("pkg", sbn.getPackageName());
            CharSequence title = n.extras.getCharSequence(Notification.EXTRA_TITLE);
            if (title != null) {
                obj.put("title", title.toString());
            }
            CharSequence text = n.extras.getCharSequence(Notification.EXTRA_TEXT);
            if (text != null) {
                obj.put("body", text.toString());
            }
            String iconB64 = renderIcon(n.getSmallIcon());
            if (iconB64 != null) {
                obj.put("icon_b64", iconB64);
            }
        } catch (JSONException e) {
            Logs.e("cannot build notify payload", e);
            return;
        }
        BridgeService.enqueue(this, obj);
    }

    // forget the notification and send a notif_gone message
    @Override
    public void onNotificationRemoved(StatusBarNotification sbn) {
        mActive.remove(sbn.getKey());
        JSONObject obj = new JSONObject();
        try {
            obj.put("t", "notif_gone");
            obj.put("key", sbn.getKey());
        } catch (JSONException e) {
            Logs.e("cannot build notif_gone payload", e);
            return;
        }
        BridgeService.enqueue(this, obj);
    }

    // cancel or open a notification
    private void onHostAction(String key, boolean close) {
        StatusBarNotification sbn = mActive.get(key);
        if (sbn == null) {
            Logs.e("notif action for unknown key " + key);
            return;
        }
        if (close) {
            cancelNotification(key);
            return;
        }
        Notification n = sbn.getNotification();
        if (n.contentIntent != null) {
            try {
                n.contentIntent.send();
            } catch (PendingIntent.CanceledException e) {
                Logs.e("contentIntent already canceled for " + key, e);
            }
        }
        if ((n.flags & Notification.FLAG_AUTO_CANCEL) != 0) {
            cancelNotification(key);
        }
    }

    // render an icon to a base64 png string
    private String renderIcon(Icon icon) {
        if (icon == null) {
            return null;
        }
        Drawable d = icon.loadDrawable(this);
        if (d == null) {
            return null;
        }
        int w = d.getIntrinsicWidth() > 0 ? d.getIntrinsicWidth() : FALLBACK_ICON_PX;
        int h = d.getIntrinsicHeight() > 0 ? d.getIntrinsicHeight() : FALLBACK_ICON_PX;
        Bitmap bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bmp);
        d.setBounds(0, 0, w, h);
        d.draw(canvas);
        ByteArrayOutputStream png = new ByteArrayOutputStream();
        bmp.compress(Bitmap.CompressFormat.PNG, 100, png);
        return Base64.encodeToString(png.toByteArray(), Base64.NO_WRAP);
    }
}
