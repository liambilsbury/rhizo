package com.rhizo.deskapp;

import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.RemoteInput;
import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.ContentResolver;
import android.content.Intent;
import android.content.res.AssetFileDescriptor;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Shader;
import android.graphics.drawable.Icon;
import android.net.Uri;
import android.os.Bundle;
import android.util.Base64;
import android.util.Log;
import android.view.DragEvent;
import android.view.MotionEvent;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

// activity for desktop bridge system tests
public class MainActivity extends Activity {
    private static final String TAG = "RhizoDeskApp";
    private static final String CHANNEL_ID = "rhizo-deskapp";
    private static final String ACTION_NOTIF_ACTIVATED = "com.rhizo.deskapp.NOTIF_ACTIVATED";
    private static final String ACTION_NOTIF_REPLIED = "com.rhizo.deskapp.NOTIF_REPLIED";
    private static final String REPLY_KEY = "rhizo_reply";

    private View dropTarget;

    // build the UI and handle the launch intent
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        buildUi();
        handleIntent(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleIntent(intent);
    }

    // build the root view and drag listeners
    private void buildUi() {
        FrameLayout root = new FrameLayout(this);
        GradientView bg = new GradientView(this);
        root.addView(bg, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        TextView label = new TextView(this);
        label.setText(getPackageName());
        label.setTextSize(24);
        label.setTextColor(0xFFFFFFFF);
        label.setPadding(24, 24, 24, 24);
        root.addView(label, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT));

        root.setOnDragListener(new View.OnDragListener() {
            @Override
            public boolean onDrag(View v, DragEvent event) {
                return onRootDrag(event);
            }
        });

        dropTarget = root;
        root.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View v, MotionEvent event) {
                Log.i(TAG, "RHIZO_TOUCH action=" + event.getActionMasked()
                        + " x=" + (int) event.getX() + " y=" + (int) event.getY());
                if (event.getActionMasked() != MotionEvent.ACTION_DOWN || armedDragClip == null) {
                    return false;
                }
                ClipData clip = armedDragClip;
                armedDragClip = null;
                boolean started = v.startDragAndDrop(clip, new View.DragShadowBuilder(v), null,
                        View.DRAG_FLAG_GLOBAL | View.DRAG_FLAG_GLOBAL_URI_READ);
                Log.i(TAG, started ? "RHIZO_DRAG_STARTED" : "RHIZO_DRAG_START_FAILED armed");
                return true;
            }
        });
        setContentView(root);
    }

    // accept drag events and call onDrop
    private boolean onRootDrag(DragEvent event) {
        switch (event.getAction()) {
            case DragEvent.ACTION_DRAG_STARTED: {
                ClipDescription d = event.getClipDescription();
                StringBuilder mimes = new StringBuilder();
                for (int i = 0; i < d.getMimeTypeCount(); i++) {
                    if (i > 0) mimes.append(',');
                    mimes.append(d.getMimeType(i));
                }
                logToken("RHIZO_DRAG_ENTERED", "mimes=" + mimes);
                return true;
            }
            case DragEvent.ACTION_DROP:
                onDrop(event);
                return true;
            default:
                return true;
        }
    }

    // log the mime type and base64 content of each dropped item
    private void onDrop(DragEvent event) {
        requestDragAndDropPermissions(event);
        ClipData clip = event.getClipData();
        try {
            for (int i = 0; i < clip.getItemCount(); i++) {
                ClipData.Item item = clip.getItemAt(i);
                byte[] bytes;
                String mime;
                Uri uri = item.getUri();
                if (uri != null) {
                    mime = getContentResolver().getType(uri);
                    bytes = readAll(uri);
                } else {
                    CharSequence text = item.getText();
                    mime = "text/plain";
                    bytes = (text != null ? text.toString() : "").getBytes(StandardCharsets.UTF_8);
                }
                logToken("RHIZO_DROP", "mime=" + mime + " b64=" + b64(bytes));
            }
        } catch (IOException e) {
            Log.e(TAG, "RHIZO_DROP_FAILED exception=" + e, e);
        }
    }

    // log the intent or run its command
    private void handleIntent(Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        if (ACTION_NOTIF_ACTIVATED.equals(action)) {
            String title = intent.getStringExtra("title");
            logToken("RHIZO_NOTIF_ACTIVATED", "title=" + (title != null ? title : ""));
            return;
        }
        if (ACTION_NOTIF_REPLIED.equals(action)) {
            String title = intent.getStringExtra("title");
            Bundle results = RemoteInput.getResultsFromIntent(intent);
            CharSequence text = results != null ? results.getCharSequence(REPLY_KEY) : null;
            logToken("RHIZO_NOTIF_REPLIED", "title=" + (title != null ? title : "")
                    + " b64=" + b64((text != null ? text.toString() : "").getBytes(StandardCharsets.UTF_8)));
            return;
        }
        if (Intent.ACTION_VIEW.equals(action) && intent.getData() != null) {
            logToken("RHIZO_VIEW", "uri=" + intent.getDataString());
            logViewBytes(intent.getData());
            return;
        }
        String cmd = intent.getStringExtra("cmd");
        if (cmd == null) return;
        try {
            runCommand(cmd, intent);
        } catch (Exception e) {
            Log.e(TAG, "RHIZO_CMD_FAILED cmd=" + cmd + " exception=" + e, e);
        }
    }

    // log the SHA-256 and length of URI data
    private void logViewBytes(Uri uri) {
        try (InputStream in = getContentResolver().openInputStream(uri)) {
            if (in == null) throw new IOException("openInputStream returned null for " + uri);
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buf = new byte[64 * 1024];
            long len = 0;
            int n;
            while ((n = in.read(buf)) >= 0) {
                digest.update(buf, 0, n);
                len += n;
            }
            logToken("RHIZO_VIEW_BYTES", "sha256=" + hex(digest.digest()) + " len=" + len);
        } catch (Exception e) {
            logToken("RHIZO_VIEW_BYTES",
                    "error=" + e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    // run the command named by the intent
    private void runCommand(String cmd, Intent intent) throws IOException {
        switch (cmd) {
            case "clip_read":
                doClipRead();
                break;
            case "clip_write":
                doClipWrite(intent.getStringExtra("mime"), intent.getStringExtra("b64"));
                break;
            case "notify":
                doNotify(intent.getStringExtra("title"), intent.getStringExtra("body"),
                        intent.getStringExtra("icon_b64"), intent.getBooleanExtra("reply", false));
                break;
            case "send_url":
                doSendUrl(intent.getStringExtra("uri"));
                break;
            case "send_share":
                doSendShare(intent.getStringExtra("text"));
                break;
            case "drag_out":
                doDragOut(intent.getStringExtra("mime"), intent.getStringExtra("b64"),
                        intent.getStringExtra("kind"));
                break;
            default:
                Log.e(TAG, "RHIZO_UNKNOWN_CMD cmd=" + cmd);
        }
    }

    // log the clipboard contents
    private void doClipRead() throws IOException {
        ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        ClipData clip = cm.hasPrimaryClip() ? cm.getPrimaryClip() : null;
        if (clip == null || clip.getItemCount() == 0) {
            logToken("RHIZO_CLIP_EMPTY", "");
            return;
        }
        for (int i = 0; i < clip.getItemCount(); i++) {
            ClipData.Item item = clip.getItemAt(i);
            Uri uri = item.getUri();
            if (uri != null) {
                String mime = getContentResolver().getType(uri);
                logToken("RHIZO_CLIP_READ", "mime=" + mime + " b64=" + b64(readAll(uri)));
            } else {
                CharSequence text = item.getText();
                byte[] bytes = (text != null ? text.toString() : "").getBytes(StandardCharsets.UTF_8);
                logToken("RHIZO_CLIP_READ", "mime=text/plain b64=" + b64(bytes));
            }
        }
    }

    // put the decoded text or staged file on the clipboard
    private void doClipWrite(String mime, String b64) throws IOException {
        byte[] bytes = Base64.decode(b64, Base64.NO_WRAP);
        ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        ClipData clip;
        if ("text/plain".equals(mime)) {
            clip = ClipData.newPlainText("rhizo-deskapp", new String(bytes, StandardCharsets.UTF_8));
        } else {
            Uri uri = stageBytes(bytes, mime);
            clip = new ClipData(new ClipDescription("rhizo-deskapp", new String[]{mime}),
                    new ClipData.Item(uri));
        }
        cm.setPrimaryClip(clip);
        logToken("RHIZO_CLIP_WROTE", "b64=" + b64(bytes));
    }

    // post a notification with an optional reply action
    private void doNotify(String title, String body, String iconB64, boolean reply) {
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(
                CHANNEL_ID, "Rhizo Desk Test", NotificationManager.IMPORTANCE_DEFAULT));

        Icon icon;
        if (iconB64 != null && !iconB64.isEmpty()) {
            byte[] png = Base64.decode(iconB64, Base64.NO_WRAP);
            icon = Icon.createWithData(png, 0, png.length);
        } else {
            icon = Icon.createWithResource(this, android.R.drawable.ic_dialog_info);
        }

        int id = (int) (System.currentTimeMillis() & 0x7fffffff);
        Intent activate = new Intent(this, MainActivity.class);
        activate.setAction(ACTION_NOTIF_ACTIVATED);
        activate.putExtra("title", title);
        activate.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent contentIntent = PendingIntent.getActivity(this, id, activate,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder builder = new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(icon)
                .setContentTitle(title)
                .setContentText(body)
                .setContentIntent(contentIntent)
                .setAutoCancel(true);
        if (reply) {
            Intent replied = new Intent(this, MainActivity.class);
            replied.setAction(ACTION_NOTIF_REPLIED);
            replied.putExtra("title", title);
            replied.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
            PendingIntent replyIntent = PendingIntent.getActivity(this, id, replied,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
            builder.addAction(new Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_menu_send), "Reply", replyIntent)
                    .addRemoteInput(new RemoteInput.Builder(REPLY_KEY).setLabel("Reply").build())
                    .build());
        }
        Notification n = builder.build();
        nm.notify(id, n);
        logToken("RHIZO_NOTIF_POSTED", "id=" + id + " title=" + title);
        if (reply) {
            int inputs = 0;
            if (n.actions != null) {
                for (Notification.Action a : n.actions) {
                    if (a.getRemoteInputs() != null) inputs += a.getRemoteInputs().length;
                }
            }
            logToken("RHIZO_NOTIF_REPLY_POSTED", "title=" + title + " remote_inputs=" + inputs);
        }
    }

    // start a view intent for the uri
    private void doSendUrl(String uri) {
        startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(uri)));
        logToken("RHIZO_SENT_VIEW", "uri=" + uri);
    }

    // start a send intent carrying the text
    private void doSendShare(String text) {
        Intent i = new Intent(Intent.ACTION_SEND);
        i.setType("text/plain");
        i.putExtra(Intent.EXTRA_TEXT, text);
        startActivity(i);
        logToken("RHIZO_SENT_SHARE", "");
    }

    private ClipData armedDragClip;

    // arm a clip of the decoded text or staged file for a drag out
    private void doDragOut(String mime, String b64, String kind) throws IOException {
        byte[] bytes = Base64.decode(b64, Base64.NO_WRAP);
        ClipData clip;
        if ("text".equals(kind)) {
            clip = ClipData.newPlainText("rhizo-deskapp-drag", new String(bytes, "UTF-8"));
        } else {
            Uri uri = stageBytes(bytes, mime);
            clip = new ClipData(new ClipDescription("rhizo-deskapp-drag", new String[]{mime}),
                    new ClipData.Item(uri));
        }
        armedDragClip = clip;
        logToken("RHIZO_DRAG_ARMED_OUT", "");
    }

    // write the bytes to a file and return its provider uri
    private Uri stageBytes(byte[] bytes, String mime) throws IOException {
        File dir = new File(getFilesDir(), "share");
        dir.mkdirs();
        String name = "item-" + System.nanoTime();
        try (FileOutputStream out = new FileOutputStream(new File(dir, name))) {
            out.write(bytes);
        }
        ShareProvider.registerMime(name, mime);
        return new Uri.Builder()
                .scheme(ContentResolver.SCHEME_CONTENT)
                .authority(ShareProvider.AUTHORITY)
                .path("/share/" + name)
                .build();
    }

    // read the whole content of a uri into memory
    private byte[] readAll(Uri uri) throws IOException {
        AssetFileDescriptor afd = getContentResolver().openAssetFileDescriptor(uri, "r");
        if (afd == null) throw new IOException("openAssetFileDescriptor returned null for " + uri);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (InputStream in = afd.createInputStream()) {
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) >= 0) out.write(buf, 0, n);
        } finally {
            afd.close();
        }
        return out.toByteArray();
    }

    // encode bytes as base64 without line breaks
    private static String b64(byte[] bytes) {
        return Base64.encodeToString(bytes, Base64.NO_WRAP);
    }

    private static final char[] HEX = "0123456789abcdef".toCharArray();

    // encode bytes as lowercase hex
    private static String hex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(HEX[(b >> 4) & 0xf]).append(HEX[b & 0xf]);
        }
        return sb.toString();
    }

    // write the token and its detail to the log
    private static void logToken(String token, String rest) {
        Log.i(TAG, rest.isEmpty() ? token : token + " " + rest);
    }

    // diagonal five-color gradient view
    private static final class GradientView extends View {
        private static final int[] COLORS = {
                0xFFFF6B35, 0xFFF7C548, 0xFF2EC4B6, 0xFF6A4C93, 0xFFE71D6A,
        };

        private final Paint paint = new Paint();

        GradientView(android.content.Context context) {
            super(context);
        }

        @Override
        protected void onSizeChanged(int w, int h, int oldW, int oldH) {
            super.onSizeChanged(w, h, oldW, oldH);
            paint.setShader(new LinearGradient(0, 0, w, h, COLORS, null, Shader.TileMode.CLAMP));
        }

        @Override
        protected void onDraw(Canvas canvas) {
            canvas.drawRect(0, 0, getWidth(), getHeight(), paint);
        }
    }
}
