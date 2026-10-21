package com.rhizo.storagetest;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Environment;
import android.os.Process;
import android.util.Log;
import android.widget.TextView;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileDescriptor;
import java.security.MessageDigest;

// activity for shared-storage system tests
public class MainActivity extends Activity {
    private static final String TAG = "RhizoStorageTest";
    private static final String DEFAULT_WRITE_CONTENT =
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd";

    private TextView tv;

    // start the storage probe thread
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        tv = new TextView(this);
        tv.setTextSize(28);
        tv.setTextColor(Color.WHITE);
        tv.setPadding(24, 24, 24, 24);
        tv.setText("RHIZO STORAGE TEST\nrunning...");
        tv.setBackgroundColor(Color.rgb(20, 20, 20));
        setContentView(tv);

        final Intent intent = getIntent();
        final String readPath = intent != null ? intent.getStringExtra("read_path") : null;
        final String writePath = intent != null ? intent.getStringExtra("write_path") : null;
        String wc = intent != null ? intent.getStringExtra("write_content") : null;
        final String writeContent = (wc != null) ? wc : DEFAULT_WRITE_CONTENT;

        new Thread(new Runnable() {
            public void run() { runProbe(readPath, writePath, writeContent); }
        }, "rhizo-storagetest-probe").start();
    }

    // read and write the storage paths
    private void runProbe(String readPath, String writePath, String writeContent) {
        StringBuilder ui = new StringBuilder();
        boolean ok = true;

        File root = Environment.getExternalStorageDirectory();
        String rootAbs = root.getAbsolutePath();
        Log.i(TAG, "RHIZO_STORAGE_ROOT path=" + rootAbs);
        ui.append("root: ").append(rootAbs).append('\n');

        Log.i(TAG, "RHIZO_STORAGE_UID uid=" + Process.myUid());
        ui.append("uid: ").append(Process.myUid()).append('\n');

        if (readPath != null) {
            File f = new File(root, readPath);
            String abs = f.getAbsolutePath();
            try {
                byte[] data = readAll(f);
                String sha = sha256Hex(data);
                Log.i(TAG, "RHIZO_STORAGE_READ_OK path=" + abs + " bytes=" + data.length + " sha256=" + sha);
                ui.append("read OK: ").append(abs).append(" (").append(data.length).append(" bytes)\n");
            } catch (Exception e) {
                ok = false;
                Log.i(TAG, "RHIZO_STORAGE_READ_FAIL path=" + abs + " err=" + e.getMessage());
                ui.append("read FAIL: ").append(abs).append(" err=").append(e.getMessage()).append('\n');
            }

            File dir = f.getParentFile();
            if (dir == null) dir = root;
            logListing(dir);
        } else {
            logListing(root);
        }

        if (writePath != null) {
            File f = new File(root, writePath);
            String abs = f.getAbsolutePath();
            try {
                byte[] data = writeContent.getBytes("UTF-8");
                writeAllSynced(f, data);
                byte[] readBack = readAll(f);
                String sha = sha256Hex(readBack);
                Log.i(TAG, "RHIZO_STORAGE_WRITE_OK path=" + abs + " bytes=" + readBack.length + " sha256=" + sha);
                ui.append("write OK: ").append(abs).append(" (").append(readBack.length).append(" bytes)\n");
            } catch (Exception e) {
                ok = false;
                Log.i(TAG, "RHIZO_STORAGE_WRITE_FAIL path=" + abs + " err=" + e.getMessage());
                ui.append("write FAIL: ").append(abs).append(" err=").append(e.getMessage()).append('\n');
            }
        }

        setResultUi(ui.toString(), ok);
    }

    // log the first entries of a directory listing
    private void logListing(File dir) {
        String abs = dir.getAbsolutePath();
        String[] names = dir.list();
        StringBuilder sb = new StringBuilder();
        if (names != null) {
            int max = Math.min(names.length, 40);
            for (int i = 0; i < max; i++) {
                if (i > 0) sb.append(',');
                sb.append(names[i]);
            }
        }
        Log.i(TAG, "RHIZO_STORAGE_LIST dir=" + abs + " entries=" + sb.toString());
    }

    // read the whole file into memory
    private static byte[] readAll(File f) throws Exception {
        FileInputStream in = new FileInputStream(f);
        try {
            long len = f.length();
            byte[] buf = new byte[(int) len];
            int off = 0;
            while (off < buf.length) {
                int n = in.read(buf, off, buf.length - off);
                if (n < 0) break;
                off += n;
            }
            if (off != buf.length) {
                byte[] trimmed = new byte[off];
                System.arraycopy(buf, 0, trimmed, 0, off);
                return trimmed;
            }
            return buf;
        } finally {
            in.close();
        }
    }

    // write the data to the file and sync it to disk
    private static void writeAllSynced(File f, byte[] data) throws Exception {
        File parent = f.getParentFile();
        if (parent != null) parent.mkdirs();
        FileOutputStream out = new FileOutputStream(f);
        try {
            out.write(data);
            out.flush();
            FileDescriptor fd = out.getFD();
            fd.sync();
        } finally {
            out.close();
        }
    }

    // return the SHA-256 of the data as lowercase hex
    private static String sha256Hex(byte[] data) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        byte[] digest = md.digest(data);
        StringBuilder sb = new StringBuilder(digest.length * 2);
        for (int i = 0; i < digest.length; i++) {
            int v = digest[i] & 0xff;
            String hex = Integer.toHexString(v);
            if (hex.length() == 1) sb.append('0');
            sb.append(hex);
        }
        return sb.toString();
    }

    // show the text on a green or red background
    private void setResultUi(final String text, final boolean ok) {
        final int bg = ok ? Color.rgb(0, 100, 0) : Color.rgb(130, 0, 0);
        runOnUiThread(new Runnable() {
            public void run() {
                tv.setText(text);
                tv.setBackgroundColor(bg);
            }
        });
    }
}
