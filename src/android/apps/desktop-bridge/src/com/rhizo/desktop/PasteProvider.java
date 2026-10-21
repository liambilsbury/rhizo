package com.rhizo.desktop;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

// ContentProvider for pasted and dropped files
public class PasteProvider extends ContentProvider {
    // report the provider as ready
    @Override
    public boolean onCreate() {
        return true;
    }

    // return the mime type saved beside the paste file
    @Override
    public String getType(Uri uri) {
        return readSidecar(uri, "mime");
    }

    // open the paste file read-only
    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        File data = new File(pasteDir(), fileName(uri));
        return ParcelFileDescriptor.open(data, ParcelFileDescriptor.MODE_READ_ONLY);
    }

    // return the file name and size
    @Override
    public Cursor query(Uri uri, String[] projection, String selection,
            String[] selectionArgs, String sortOrder) {
        File data = new File(pasteDir(), fileName(uri));
        String name = readSidecar(uri, "name");
        MatrixCursor cursor = new MatrixCursor(
                new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
        cursor.addRow(new Object[] {name != null ? name : data.getName(), data.length()});
        return cursor;
    }

    // reject inserts
    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException();
    }

    // reject deletes
    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException();
    }

    // reject updates
    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException();
    }

    // return the paste directory
    private File pasteDir() {
        return new File(getContext().getFilesDir(), "paste");
    }

    // read a sidecar text file
    private String readSidecar(Uri uri, String suffix) {
        File f = new File(pasteDir(), fileName(uri) + "." + suffix);
        try {
            return new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8).trim();
        } catch (IOException e) {
            return null;
        }
    }

    // return the file name from the uri path
    private static String fileName(Uri uri) {
        String path = uri.getPath();
        return path.startsWith("/") ? path.substring(1) : path;
    }
}
