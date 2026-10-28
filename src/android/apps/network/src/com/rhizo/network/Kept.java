package com.rhizo.network;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

// the mirrored SSIDs kept suggested, newest first
final class Kept {
    static final int MAX = 16;
    private static final String PREFS = "mirror";
    private static final String KEY = "kept";

    private final SharedPreferences mPrefs;

    Kept(Context ctx) {
        mPrefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    // return the stored list, newest first
    List<String> load() {
        List<String> out = new ArrayList<>();
        for (String s : mPrefs.getString(KEY, "").split(",")) {
            String hex = normalize(s);
            if (hex != null && !out.contains(hex) && out.size() < MAX) {
                out.add(hex);
            }
        }
        return out;
    }

    // return the newest mirrored SSID, or null
    String current() {
        List<String> list = load();
        return list.isEmpty() ? null : list.get(0);
    }

    // return the stored list with hex moved to the front
    List<String> promote(String hex) {
        List<String> out = load();
        out.remove(hex);
        out.add(0, hex);
        while (out.size() > MAX) {
            out.remove(out.size() - 1);
        }
        return out;
    }

    void save(List<String> list) {
        StringBuilder sb = new StringBuilder();
        for (String hex : list) {
            if (sb.length() > 0) {
                sb.append(',');
            }
            sb.append(hex);
        }
        mPrefs.edit().putString(KEY, sb.toString()).commit();
    }

    static List<String> only(String hex) {
        List<String> out = new ArrayList<>();
        out.add(hex);
        return out;
    }

    // return s as lowercase hex of 1-32 bytes, or null
    static String normalize(String s) {
        if (s == null) {
            return null;
        }
        String hex = s.trim().toLowerCase(Locale.ROOT);
        if (hex.isEmpty() || hex.length() > 64 || hex.length() % 2 != 0) {
            return null;
        }
        for (int i = 0; i < hex.length(); i++) {
            char c = hex.charAt(i);
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
                return null;
            }
        }
        return hex;
    }

    // return the bytes of normalized hex
    static byte[] bytes(String hex) {
        byte[] out = new byte[hex.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(hex.substring(2 * i, 2 * i + 2), 16);
        }
        return out;
    }

    // return bytes as lowercase hex
    static String hex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(String.format(Locale.ROOT, "%02x", b & 0xff));
        }
        return sb.toString();
    }
}
