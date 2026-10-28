package com.rhizo.network;

import android.net.wifi.WifiManager;
import android.net.wifi.WifiNetworkSuggestion;
import android.net.wifi.WifiSsid;
import android.util.Log;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

// keep the app's Wi-Fi suggestions equal to the kept list
final class Suggestions {
    private Suggestions() {}

    // build the open suggestion for a hex SSID
    static WifiNetworkSuggestion build(String hex) {
        return new WifiNetworkSuggestion.Builder()
                .setWifiSsid(WifiSsid.fromBytes(Kept.bytes(hex)))
                .build();
    }

    // remove unwanted suggestions, then add the missing ones
    static int reconcile(WifiManager wifi, List<String> want, String current, boolean connected,
            boolean debug, String what) {
        // re-adding the current SSID discards a no-internet latch left on its ephemeral config
        Set<String> present = new HashSet<>();
        List<WifiNetworkSuggestion> drop = new ArrayList<>();
        List<String> dropHex = new ArrayList<>();
        for (WifiNetworkSuggestion s : wifi.getNetworkSuggestions()) {
            WifiSsid ssid = s.getWifiSsid();
            String hex = ssid == null ? null : Kept.hex(ssid.getBytes());
            if (hex != null && want.contains(hex) && (connected || !hex.equals(current))) {
                present.add(hex);
            } else {
                drop.add(s);
                dropHex.add(hex);
            }
        }
        if (!drop.isEmpty()) {
            int status = wifi.removeNetworkSuggestions(drop,
                    WifiManager.ACTION_REMOVE_SUGGESTION_DISCONNECT);
            Log.i(Mirror.TAG, what + ": remove n=" + drop.size() + " status=" + status
                    + (debug ? " ssid_hex=" + dropHex : ""));
            if (status != WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS
                    && status != WifiManager.STATUS_NETWORK_SUGGESTIONS_ERROR_REMOVE_INVALID) {
                return status;
            }
        }
        List<WifiNetworkSuggestion> add = new ArrayList<>();
        List<String> addHex = new ArrayList<>();
        for (String hex : want) {
            if (!present.contains(hex)) {
                add.add(build(hex));
                addHex.add(hex);
            }
        }
        if (add.isEmpty()) {
            return WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS;
        }
        int status = wifi.addNetworkSuggestions(add);
        Log.i(Mirror.TAG, what + ": add n=" + add.size() + " status=" + status
                + (debug ? " ssid_hex=" + addHex : ""));
        return status;
    }
}
