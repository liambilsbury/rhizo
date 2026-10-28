package com.rhizo.desktop;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.os.Process;

import java.io.IOException;

// provider for bridge credentials
public class TokenProvider extends ContentProvider {
    static final String METHOD_MINT = "mint";
    static final String METHOD_START = "start";
    static final String KEY_TOKEN = "token";
    private static final String ONLY_CALL = "the token provider serves call() only";

    // report the provider as ready
    @Override
    public boolean onCreate() {
        return true;
    }

    // mint the credentials or start the bridge
    @Override
    public Bundle call(String method, String arg, Bundle extras) {
        int uid = Binder.getCallingUid();
        if (uid != Process.ROOT_UID && uid != Process.SHELL_UID) {
            throw new SecurityException("uid " + uid + " may not reach the bridge credentials");
        }
        Bundle reply = new Bundle();
        if (METHOD_MINT.equals(method)) {
            int port = parsePort(arg);
            DeskCreds creds;
            try {
                creds = DeskCreds.mint(getContext(), port);
            } catch (IOException e) {
                throw new IllegalStateException("could not persist the bridge credentials: " + e);
            }
            Logs.i("RHIZO_DESK_TOKEN_MINTED port=" + port);
            reply.putString(KEY_TOKEN, creds.token);
            return reply;
        }
        if (METHOD_START.equals(method)) {
            try {
                if (DeskCreds.load(getContext()) == null) {
                    throw new IllegalStateException("start before any mint: no bridge credentials yet");
                }
            } catch (IOException e) {
                throw new IllegalStateException("unreadable bridge credentials: " + e);
            }
            BridgeService.start(getContext());
            reply.putBoolean("started", true);
            return reply;
        }
        throw new IllegalArgumentException("unknown method " + method);
    }

    // parse a port number between 1 and 65535
    private static int parsePort(String arg) {
        int port;
        try {
            port = Integer.parseInt(arg);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("mint wants a port, got " + arg);
        }
        if (port <= 0 || port > 65535) {
            throw new IllegalArgumentException("mint wants a port, got " + port);
        }
        return port;
    }

    // reject queries
    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs,
            String sortOrder) {
        throw new UnsupportedOperationException(ONLY_CALL);
    }

    // reject type lookups
    @Override
    public String getType(Uri uri) {
        throw new UnsupportedOperationException(ONLY_CALL);
    }

    // reject inserts
    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException(ONLY_CALL);
    }

    // reject deletes
    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException(ONLY_CALL);
    }

    // reject updates
    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException(ONLY_CALL);
    }
}
