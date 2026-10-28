package com.rhizo.home;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.content.res.Configuration;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.net.Uri;
import android.os.Binder;
import android.os.ParcelFileDescriptor;
import android.util.DisplayMetrics;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.OutputStream;
import java.util.List;
import java.util.regex.Pattern;

// serve an app's launcher icon as a PNG
public class IconProvider extends ContentProvider {
    private static final String TAG = "RhizoHomeIcons";
    private static final int DEFAULT_SIZE = 256;
    private static final int MIN_SIZE = 16;
    private static final int MAX_SIZE = 1024;
    private static final int ROOT_UID = 0;
    private static final int SYSTEM_UID = 1000;
    private static final int SHELL_UID = 2000;
    private static final Pattern PACKAGE = Pattern.compile("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+");

    @Override
    public boolean onCreate() {
        return true;
    }

    // open a pipe carrying the package's launcher icon as a PNG
    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        int uid = Binder.getCallingUid();
        if (uid != ROOT_UID && uid != SHELL_UID && uid != SYSTEM_UID) {
            throw new SecurityException("app icons are served to root, shell and system, not uid " + uid);
        }
        if (!"r".equals(mode)) {
            throw new FileNotFoundException("icons open read-only, not '" + mode + "'");
        }
        String pkg = uri.getLastPathSegment();
        if (pkg == null || !PACKAGE.matcher(pkg).matches()) {
            throw new FileNotFoundException("'" + pkg + "' is not a package name");
        }
        int size = DEFAULT_SIZE;
        String asked = uri.getQueryParameter("size");
        if (asked != null) {
            try {
                size = Integer.parseInt(asked);
            } catch (NumberFormatException e) {
                throw new FileNotFoundException("size '" + asked + "' is not a number");
            }
        }
        if (size < MIN_SIZE || size > MAX_SIZE) {
            throw new FileNotFoundException("size " + size + " is outside " + MIN_SIZE + "-" + MAX_SIZE);
        }
        final byte[] png = render(pkg, size);
        final ParcelFileDescriptor[] pipe;
        try {
            pipe = ParcelFileDescriptor.createPipe();
        } catch (IOException e) {
            throw new FileNotFoundException("no pipe for " + pkg + "'s icon: " + e);
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                try (OutputStream out = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                    out.write(png);
                } catch (IOException e) {
                    Log.w(TAG, "writing the icon of " + pkg + " failed", e);
                }
            }
        }, "rhizo-icon-" + pkg).start();
        return pipe[0];
    }

    // draw the package's launcher icon into a square PNG
    private byte[] render(String pkg, int size) throws FileNotFoundException {
        PackageManager pm = getContext().getPackageManager();
        ApplicationInfo ai;
        try {
            ai = pm.getApplicationInfo(pkg, 0);
        } catch (PackageManager.NameNotFoundException e) {
            throw new FileNotFoundException("no package " + pkg);
        }
        Intent launch = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(pkg);
        List<ResolveInfo> launchers = pm.queryIntentActivities(launch, 0);
        ResolveInfo ri = launchers.isEmpty() ? null : launchers.get(0);
        int res = ri != null ? ri.getIconResource() : ai.icon;
        Drawable icon = null;
        if (res != 0) {
            // getDrawableForDensity loads an adaptive icon's layers at the display density
            try {
                Configuration dense = new Configuration(getContext().getResources().getConfiguration());
                dense.densityDpi = DisplayMetrics.DENSITY_XXXHIGH;
                Context app = getContext().createPackageContext(pkg, 0).createConfigurationContext(dense);
                icon = app.getResources().getDrawable(res, null);
            } catch (PackageManager.NameNotFoundException | RuntimeException e) {
                Log.w(TAG, pkg + "'s icon resource 0x" + Integer.toHexString(res) + " did not load", e);
            }
        }
        if (icon == null) {
            icon = ri != null ? ri.loadIcon(pm) : pm.getApplicationIcon(ai);
        }
        Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        icon.setBounds(0, 0, size, size);
        icon.draw(new Canvas(bitmap));
        ByteArrayOutputStream png = new ByteArrayOutputStream();
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, png)) {
            throw new FileNotFoundException("PNG encoding of " + pkg + "'s icon failed");
        }
        bitmap.recycle();
        return png.toByteArray();
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
        return null;
    }

    @Override
    public String getType(Uri uri) {
        return "image/png";
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException("icons are read-only");
    }

    @Override
    public int delete(Uri uri, String selection, String[] args) {
        throw new UnsupportedOperationException("icons are read-only");
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] args) {
        throw new UnsupportedOperationException("icons are read-only");
    }
}
