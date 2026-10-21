package com.rhizo.deskapp;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileNotFoundException;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

// ContentProvider for staged share files
public final class ShareProvider extends ContentProvider {
    static final String AUTHORITY = "com.rhizo.deskapp.provider";
    private static final Map<String, String> MIME_BY_NAME = new ConcurrentHashMap<>();

    // remember the mime type of a staged file
    static void registerMime(String name, String mime) {
        MIME_BY_NAME.put(name, mime);
    }

    // report the provider as ready
    @Override
    public boolean onCreate() {
        return true;
    }

    // return the staged file a uri names
    private File fileFor(Uri uri) {
        return new File(getContext().getFilesDir(), uri.getPath());
    }

    // return the mime type of the uri's file
    @Override
    public String getType(Uri uri) {
        String mime = MIME_BY_NAME.get(new File(uri.getPath()).getName());
        return mime != null ? mime : "application/octet-stream";
    }

    // open the staged file read-only
    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        return ParcelFileDescriptor.open(fileFor(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    // return a cursor with the file's name and size
    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        File f = fileFor(uri);
        if (!f.isFile()) return null;
        String[] cols = projection != null ? projection
                : new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE};
        MatrixCursor cursor = new MatrixCursor(cols);
        Object[] row = new Object[cols.length];
        for (int i = 0; i < cols.length; i++) {
            if (OpenableColumns.DISPLAY_NAME.equals(cols[i])) row[i] = f.getName();
            else if (OpenableColumns.SIZE.equals(cols[i])) row[i] = f.length();
        }
        cursor.addRow(row);
        return cursor;
    }

    // reject inserts
    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException("write through MainActivity, not the provider");
    }

    // ignore deletes and report zero rows
    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    // ignore updates and report zero rows
    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        return 0;
    }
}
