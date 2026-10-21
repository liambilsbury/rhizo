package com.rhizo.desktop;

import android.content.Context;
import android.util.AtomicFile;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;

// token and port for the bridge
final class DeskCreds {
    private static final String FILE_NAME = "desk-creds";
    private static final int TOKEN_BYTES = 16;

    final String token;
    final int port;

    // store the token and port
    private DeskCreds(String token, int port) {
        this.token = token;
        this.port = port;
    }

    // write the token and port file
    static DeskCreds mint(Context context, int port) throws IOException {
        byte[] bytes = new byte[TOKEN_BYTES];
        new SecureRandom().nextBytes(bytes);
        DeskCreds creds = new DeskCreds(DeskAuth.hex(bytes), port);
        AtomicFile file = file(context);
        FileOutputStream out = file.startWrite();
        try {
            out.write((port + "\n" + creds.token + "\n").getBytes(StandardCharsets.UTF_8));
            file.finishWrite(out);
        } catch (IOException e) {
            file.failWrite(out);
            throw e;
        }
        return creds;
    }

    // read the credentials file
    static DeskCreds load(Context context) throws IOException {
        byte[] bytes;
        try {
            bytes = file(context).readFully();
        } catch (FileNotFoundException e) {
            return null;
        }
        String[] lines = new String(bytes, StandardCharsets.UTF_8).split("\n");
        if (lines.length < 2) {
            throw new IOException("credentials file has " + lines.length + " lines, want 2");
        }
        int port;
        try {
            port = Integer.parseInt(lines[0].trim());
        } catch (NumberFormatException e) {
            throw new IOException("credentials file has a bad port: " + lines[0]);
        }
        String token = lines[1].trim();
        if (port <= 0 || token.length() != TOKEN_BYTES * 2) {
            throw new IOException("credentials file has port " + port + " and a "
                    + token.length() + "-char token");
        }
        return new DeskCreds(token, port);
    }

    // return the atomic file holding the credentials
    private static AtomicFile file(Context context) {
        return new AtomicFile(new File(context.getFilesDir(), FILE_NAME));
    }
}
