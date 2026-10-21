package com.rhizo.desktop;

import java.util.Arrays;

// echo check for host clips
final class HostClipEcho {
    static final String LABEL = "rhizo-desktop";

    private String mMime;
    private byte[] mBytes;

    // record the host clip and its mime type
    synchronized void hostSet(String mime, byte[] bytes) {
        mMime = mime;
        mBytes = bytes.clone();
    }

    // compare a clipboard change with the host clip
    synchronized boolean isEcho(CharSequence label, String mime, byte[] bytes) {
        return label != null && LABEL.contentEquals(label)
                && mime.equals(mMime) && Arrays.equals(bytes, mBytes);
    }
}
