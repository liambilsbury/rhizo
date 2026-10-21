package com.rhizo.desktop;

import android.app.Service;
import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Base64;
import android.widget.Toast;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

// service for the desktop bridge connection
public class BridgeService extends Service {
    static final String AUTHORITY = "com.rhizo.desktop.paste";

    private static final String HOST_ADDR = "192.168.100.1";
    private static final int HELLO_TIMEOUT_MS = 5000;
    private static final long INITIAL_BACKOFF_MS = 1000;
    private static final long MAX_BACKOFF_MS = 30000;
    private static final int MAX_LINE_BYTES = 8 * 1024 * 1024;
    private static final int MAX_QUEUED_LINES = 200;
    private static final String EXTRA_ENQUEUE = "enqueue";

    private static volatile BridgeService sInstance;

    private final SecureRandom mRandom = new SecureRandom();
    private final Object mCredsLock = new Object();
    private String mToken;
    private int mPort;

    private final Object mSockLock = new Object();
    private Socket mSocket;
    private OutputStream mOut;

    private final Object mWaitLock = new Object();
    private Thread mReaderThread;
    private volatile boolean mStopped;

    private final Object mQueueLock = new Object();
    private final ArrayDeque<String> mPendingLines = new ArrayDeque<>();

    private ExecutorService mSendExecutor;
    private ClipboardManager mClipboardManager;
    private ClipboardManager.OnPrimaryClipChangedListener mClipListener;

    private final HostClipEcho mHostClips = new HostClipEcho();

    // queue a line for the host bridge
    static void enqueue(Context context, JSONObject payload) {
        BridgeService live = sInstance;
        if (live != null) {
            final JSONObject obj = payload;
            live.mSendExecutor.execute(new Runnable() {
                @Override
                public void run() {
                    live.sendOrQueue(obj);
                }
            });
            return;
        }
        Intent intent = new Intent(context, BridgeService.class);
        intent.putExtra(EXTRA_ENQUEUE, payload.toString());
        context.startService(intent);
    }

    // return no binder
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // start the clipboard listener and reader thread
    @Override
    public void onCreate() {
        super.onCreate();
        mSendExecutor = Executors.newSingleThreadExecutor();
        mClipboardManager = getSystemService(ClipboardManager.class);
        mClipListener = new ClipboardManager.OnPrimaryClipChangedListener() {
            @Override
            public void onPrimaryClipChanged() {
                onClipChanged();
            }
        };
        mClipboardManager.addPrimaryClipChangedListener(mClipListener);
        mReaderThread = new Thread(new Runnable() {
            @Override
            public void run() {
                readerLoop();
            }
        }, "rhizo-desk-io");
        mReaderThread.start();
        sInstance = this;
    }

    // start BridgeService
    static void start(Context context) {
        context.startService(new Intent(context, BridgeService.class));
    }

    // start BridgeService from saved credentials
    static void startIfMinted(Context context, String from) {
        try {
            if (DeskCreds.load(context) == null) {
                return;
            }
            start(context);
        } catch (IOException | IllegalStateException e) {
            Logs.e("RHIZO_DESK_RESTART_FAILED from=" + from, e);
        }
    }

    // reload credentials and queue the enqueued line
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        reloadCreds();
        final String enqueued = intent == null ? null : intent.getStringExtra(EXTRA_ENQUEUE);
        if (enqueued != null) {
            mSendExecutor.execute(new Runnable() {
                @Override
                public void run() {
                    try {
                        sendOrQueue(new JSONObject(enqueued));
                    } catch (JSONException e) {
                        Logs.e("dropping malformed enqueue payload", e);
                    }
                }
            });
        }
        return START_STICKY;
    }

    // stop the threads, socket and clipboard listener
    @Override
    public void onDestroy() {
        sInstance = null;
        mStopped = true;
        synchronized (mWaitLock) {
            mWaitLock.notifyAll();
        }
        closeSocket();
        mClipboardManager.removePrimaryClipChangedListener(mClipListener);
        mSendExecutor.shutdownNow();
        super.onDestroy();
    }

    // reload the credentials and restart the connection
    private void reloadCreds() {
        DeskCreds creds;
        try {
            creds = DeskCreds.load(this);
        } catch (IOException e) {
            Logs.e("RHIZO_DESK_CREDS_UNREADABLE", e);
            return;
        }
        if (creds == null) {
            Logs.i("RHIZO_DESK_NO_CREDS: nothing minted yet");
            return;
        }
        synchronized (mCredsLock) {
            if (creds.token.equals(mToken) && creds.port == mPort) {
                return;
            }
        }
        restart(creds.token, creds.port);
    }

    // store credentials and reconnect
    private void restart(String token, int port) {
        synchronized (mCredsLock) {
            mToken = token;
            mPort = port;
        }
        closeSocket();
        synchronized (mWaitLock) {
            mWaitLock.notifyAll();
        }
    }

    private void closeSocket() {
        synchronized (mSockLock) {
            if (mSocket != null) {
                try {
                    mSocket.close();
                } catch (IOException e) {
                }
                mSocket = null;
                mOut = null;
            }
        }
    }

    // connect to the host and read lines
    private void readerLoop() {
        long backoff = INITIAL_BACKOFF_MS;
        while (!mStopped) {
            String token;
            int port;
            synchronized (mCredsLock) {
                token = mToken;
                port = mPort;
            }
            if (token == null) {
                waitFor(MAX_BACKOFF_MS);
                continue;
            }
            boolean everConnected = connectAndPump(token, port);
            if (mStopped) {
                break;
            }
            backoff = everConnected ? INITIAL_BACKOFF_MS : Math.min(backoff * 2, MAX_BACKOFF_MS);
            waitFor(backoff);
        }
    }

    // wait up to the given milliseconds or until woken
    private void waitFor(long ms) {
        synchronized (mWaitLock) {
            try {
                mWaitLock.wait(ms);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }

    // connect to the host and read lines
    private boolean connectAndPump(String token, int port) {
        Socket sock = new Socket();
        try {
            sock.connect(new InetSocketAddress(HOST_ADDR, port), HELLO_TIMEOUT_MS);
            sock.setKeepAlive(true);
            sock.setSoTimeout(HELLO_TIMEOUT_MS);
            final OutputStream out = sock.getOutputStream();
            final LineReader in = new LineReader(new BufferedInputStream(sock.getInputStream()));

            DeskAuth.handshake(new DeskAuth.Lines() {
                @Override
                public String read() throws IOException {
                    return in.readLine();
                }

                @Override
                public void write(String line) throws IOException {
                    writeLine(out, line);
                }
            }, token, mRandom);

            String reply = in.readLine();
            if (reply == null) {
                throw new IOException("connection closed during hello");
            }
            JSONObject obj = new JSONObject(reply);
            if (!"hello_ok".equals(obj.optString("t"))) {
                throw new IOException("host rejected hello: " + reply);
            }

            sock.setSoTimeout(0);
            synchronized (mSockLock) {
                mSocket = sock;
                mOut = out;
            }
            Logs.i("RHIZO_DESK_CONNECTED port=" + port);
            drainQueue();

            String line;
            while ((line = in.readLine()) != null) {
                handleLine(line, out);
            }
            return true;
        } catch (DeskAuth.HostUnproven e) {
            Logs.e("RHIZO_DESK_HOST_UNPROVEN port=" + port + " reason=" + e.getMessage());
            return false;
        } catch (IOException | JSONException e) {
            Logs.e("RHIZO_DESK_CONNECT_FAILED reason=" + e);
            return false;
        } finally {
            closeSocket();
        }
    }

    // write the queued lines to the socket
    private void drainQueue() {
        for (;;) {
            String line;
            synchronized (mQueueLock) {
                line = mPendingLines.pollFirst();
            }
            if (line == null) {
                return;
            }
            OutputStream out;
            synchronized (mSockLock) {
                out = mOut;
            }
            if (out == null) {
                requeueFirst(line);
                return;
            }
            try {
                writeLine(out, line);
            } catch (LineTooLargeException e) {
                Logs.e("dropping queued line that is too large to send", e);
            } catch (IOException e) {
                Logs.e("drain failed, requeuing pending line", e);
                requeueFirst(line);
                return;
            }
        }
    }

    // put a line back at the front of the pending queue
    private void requeueFirst(String line) {
        synchronized (mQueueLock) {
            mPendingLines.addFirst(line);
        }
    }

    // process a JSON line from the host
    private void handleLine(String line, OutputStream out) throws IOException, JSONException {
        JSONObject obj = new JSONObject(line);
        switch (obj.getString("t")) {
            case "ping":
                JSONObject pong = new JSONObject();
                pong.put("t", "pong");
                writeLine(out, pong.toString());
                break;
            case "clip_set":
                applyHostClip(obj);
                break;
            case "notif_action":
                if (!NotifListener.dispatch(obj.getString("key"), false)) {
                    Logs.e("notif_action for " + obj.getString("key") + " with no listener connected");
                }
                break;
            case "notif_close":
                if (!NotifListener.dispatch(obj.getString("key"), true)) {
                    Logs.e("notif_close for " + obj.getString("key") + " with no listener connected");
                }
                break;
            case "drop":
                DropCatcher.handleDrop(this, obj);
                break;
            case "drop_cancel":
                DropCatcher.cancel();
                break;
            case "dragwatch":
                DropCatcher.handleDragwatch(this, obj);
                break;
            case "dragwatch_off":
                DropCatcher.cancel();
                break;
            case "open_failed":
                showOpenFailed(obj.getString("uri"), obj.getString("why"));
                break;
            default:
                break;
        }
    }

    // show a toast for a failed link open
    private void showOpenFailed(final String uri, final String why) {
        Logs.i("RHIZO_LINK_FAILED uri=" + uri + " why=" + why);
        new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override
            public void run() {
                Toast.makeText(BridgeService.this, "Couldn't open the link on the desktop: " + why,
                        Toast.LENGTH_LONG).show();
            }
        });
    }

    // set the Android clipboard from a host clip
    private void applyHostClip(JSONObject obj) throws JSONException {
        String mime = obj.getString("mime");
        byte[] bytes = Base64.decode(obj.getString("b64"), Base64.NO_WRAP);
        if (mime.startsWith("text/")) {
            String text = new String(bytes, StandardCharsets.UTF_8);
            mHostClips.hostSet("text/plain", text.getBytes(StandardCharsets.UTF_8));
            mClipboardManager.setPrimaryClip(ClipData.newPlainText(HostClipEcho.LABEL, text));
            logApplied(mime, bytes);
        } else if (mime.startsWith("image/")) {
            Uri uri;
            try {
                uri = writePasteFile(bytes, mime);
            } catch (IOException e) {
                Logs.e("cannot stage pasted image", e);
                return;
            }
            mHostClips.hostSet(mime, bytes);
            mClipboardManager.setPrimaryClip(
                    ClipData.newUri(getContentResolver(), HostClipEcho.LABEL, uri));
            logApplied(mime, bytes);
        } else {
            Logs.e("clip_set with unsupported mime " + mime);
        }
    }

    // log the clip MIME type and SHA-256
    private static void logApplied(String mime, byte[] bytes) {
        String sha = "";
        try {
            sha = DeskAuth.hex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (NoSuchAlgorithmException e) {
            Logs.e("no SHA-256 to name the applied clip", e);
        }
        Logs.i("RHIZO_DESK_CLIP_APPLIED mime=" + mime + " sha256=" + sha);
    }

    // store clip bytes as a paste file and return its uri
    private Uri writePasteFile(byte[] bytes, String mime) throws IOException {
        return PasteStore.write(this, bytes, mime, "clip_", null);
    }

    // send the current clip on the send executor
    private void onClipChanged() {
        mSendExecutor.execute(new Runnable() {
            @Override
            public void run() {
                sendCurrentClip();
            }
        });
    }

    // send the primary clip as text or image
    private void sendCurrentClip() {
        ClipData clip = mClipboardManager.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) {
            return;
        }
        ClipDescription desc = clip.getDescription();
        CharSequence label = desc.getLabel();
        String mime = desc.getMimeTypeCount() > 0 ? desc.getMimeType(0) : null;
        ClipData.Item item = clip.getItemAt(0);
        try {
            if (mime != null && mime.startsWith("text/") && item.getText() != null) {
                sendText(label, item.getText().toString());
            } else if (mime != null && mime.startsWith("image/") && item.getUri() != null
                    && "content".equals(item.getUri().getScheme())) {
                sendImage(label, item.getUri(), mime);
            }
        } catch (IOException e) {
            Logs.e("failed to read or send clip", e);
        }
    }

    // send clipboard text to the host
    private void sendText(CharSequence label, String text) throws IOException {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        if (mHostClips.isEcho(label, "text/plain", bytes)) {
            return;
        }
        sendClipPayload("text/plain", bytes);
    }

    // send an image clip unless it echoes one from the host
    private void sendImage(CharSequence label, Uri uri, String mime) throws IOException {
        byte[] bytes = readAll(uri);
        if (mHostClips.isEcho(label, mime, bytes)) {
            return;
        }
        sendClipPayload(mime, bytes);
    }

    // read all bytes from a content uri
    private byte[] readAll(Uri uri) throws IOException {
        try (InputStream in = getContentResolver().openInputStream(uri)) {
            if (in == null) {
                throw new IOException("openInputStream returned null for " + uri);
            }
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int n;
            while ((n = in.read(chunk)) >= 0) {
                buf.write(chunk, 0, n);
            }
            return buf.toByteArray();
        }
    }

    // send a clip_set line to the host
    private void sendClipPayload(String mime, byte[] bytes) throws IOException {
        OutputStream out;
        synchronized (mSockLock) {
            out = mOut;
        }
        if (out == null) {
            return;
        }
        JSONObject obj = new JSONObject();
        try {
            obj.put("t", "clip_set");
            obj.put("mime", mime);
            obj.put("b64", Base64.encodeToString(bytes, Base64.NO_WRAP));
        } catch (JSONException e) {
            throw new IOException(e);
        }
        writeLine(out, obj.toString());
    }

    // write or queue a line
    private void sendOrQueue(JSONObject obj) {
        String line = obj.toString();
        OutputStream out;
        synchronized (mSockLock) {
            out = mOut;
        }
        if (out != null) {
            try {
                writeLine(out, line);
                return;
            } catch (LineTooLargeException e) {
                Logs.e("dropping outbound line that is too large to send", e);
                return;
            } catch (IOException e) {
                Logs.e("send failed, queuing for the next connection", e);
            }
        }
        synchronized (mQueueLock) {
            if (mPendingLines.size() >= MAX_QUEUED_LINES) {
                mPendingLines.removeFirst();
                Logs.e("outbound queue full, dropped oldest pending line");
            }
            mPendingLines.addLast(line);
        }
    }

    // write a line to the socket
    private static void writeLine(OutputStream out, String line) throws IOException {
        byte[] bytes = line.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > MAX_LINE_BYTES) {
            throw new LineTooLargeException(
                    "outbound line is " + bytes.length + " bytes, over the " + MAX_LINE_BYTES + " cap");
        }
        synchronized (out) {
            out.write(bytes);
            out.write('\n');
            out.flush();
        }
    }

    private static final class LineTooLargeException extends IOException {
        LineTooLargeException(String msg) {
            super(msg);
        }
    }

    // line input over an InputStream
    private static final class LineReader {
        private final InputStream mIn;

        LineReader(InputStream in) {
            mIn = in;
        }

        String readLine() throws IOException {
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            int b;
            while ((b = mIn.read()) != -1) {
                if (b == '\n') {
                    return buf.toString("UTF-8");
                }
                if (buf.size() >= MAX_LINE_BYTES) {
                    throw new IOException(
                            "inbound line over " + MAX_LINE_BYTES + " bytes, refusing rather than truncating");
                }
                buf.write(b);
            }
            return buf.size() == 0 ? null : buf.toString("UTF-8");
        }
    }
}
