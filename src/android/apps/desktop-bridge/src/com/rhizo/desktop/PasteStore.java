package com.rhizo.desktop;

import android.content.Context;
import android.net.Uri;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

// storage for pasted files
final class PasteStore {
    // forbid instances
    private PasteStore() {}

    // write the paste files and return a URI
    static Uri write(Context context, byte[] bytes, String mime, String prefix, String displayName)
            throws IOException {
        File dir = new File(context.getFilesDir(), "paste");
        if (!dir.exists() && !dir.mkdirs()) {
            throw new IOException("cannot create " + dir);
        }
        String name = prefix + System.nanoTime();
        try (FileOutputStream out = new FileOutputStream(new File(dir, name))) {
            out.write(bytes);
        }
        try (FileOutputStream out = new FileOutputStream(new File(dir, name + ".mime"))) {
            out.write(mime.getBytes(StandardCharsets.UTF_8));
        }
        if (displayName != null) {
            try (FileOutputStream out = new FileOutputStream(new File(dir, name + ".name"))) {
                out.write(displayName.getBytes(StandardCharsets.UTF_8));
            }
        }
        return new Uri.Builder().scheme("content").authority(BridgeService.AUTHORITY).path("/" + name).build();
    }
}
