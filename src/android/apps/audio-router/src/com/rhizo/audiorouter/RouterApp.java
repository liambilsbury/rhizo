package com.rhizo.audiorouter;

import android.app.Application;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.audiopolicy.AudioMix;
import android.media.audiopolicy.AudioMixingRule;
import android.media.audiopolicy.AudioPolicy;
import android.os.FileObserver;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

// application for per-app audio routing
public class RouterApp extends Application {
    static final String TAG = "RhizoAudioRouter";
    static final String MAP_DIR = "/data/rhizo_audio_map";
    static final String MAP_FILE = "audio_map";
    static final String STATE_FILE = "audio_map.state";

    private static RouterApp sInstance;

    private final Map<Integer, String> mUidToBus = new LinkedHashMap<>();
    private final Map<Integer, AudioMix> mAttached = new HashMap<>();
    private AudioManager mAudioManager;
    private AudioPolicy mPolicy;
    private FileObserver mObserver;

    // return the running router instance
    public static RouterApp get() {
        return sInstance;
    }

    // set up the map file observer
    @Override
    public void onCreate() {
        super.onCreate();
        sInstance = this;
        mAudioManager = getSystemService(AudioManager.class);
        final File dir = new File(MAP_DIR);
        mObserver = new FileObserver(dir.getAbsolutePath(),
                FileObserver.CLOSE_WRITE | FileObserver.MOVED_TO | FileObserver.CREATE) {
            @Override
            public void onEvent(int event, String path) {
                if (MAP_FILE.equals(path)) {
                    reload();
                }
            }
        };
        mObserver.startWatching();
        Log.i(TAG, "router up, watching " + new File(dir, MAP_FILE));
        reload();
    }

    // read the map file and rebuild the policy
    synchronized void reload() {
        final File map = new File(MAP_DIR, MAP_FILE);
        mUidToBus.clear();
        if (map.exists()) {
            try (BufferedReader r = new BufferedReader(new FileReader(map))) {
                String line;
                while ((line = r.readLine()) != null) {
                    String[] parts = line.trim().split("\\s+");
                    if (parts.length != 2) {
                        continue;
                    }
                    String bus = parts[0];
                    String pkg = parts[1];
                    try {
                        int uid = getPackageManager().getPackageUid(pkg, 0);
                        mUidToBus.put(uid, bus);
                    } catch (Exception e) {
                        Log.e(TAG, "reload: cannot resolve " + pkg, e);
                    }
                }
            } catch (Exception e) {
                Log.e(TAG, "reload: cannot read " + map, e);
            }
        }
        boolean ok = rebuild();
        writeState(ok);
    }

    // return the registered state and the uid-to-bus map as text
    synchronized String describe() {
        StringBuilder sb = new StringBuilder();
        sb.append("registered=").append(mPolicy != null);
        for (Map.Entry<Integer, String> e : mUidToBus.entrySet()) {
            sb.append(' ').append(e.getKey()).append("->").append(e.getValue());
        }
        return sb.toString();
    }

    private void writeState(boolean ok) {
        String state = (ok ? "ok " : "failed ") + describe();
        File tmp = new File(MAP_DIR, STATE_FILE + ".tmp");
        try (FileWriter w = new FileWriter(tmp)) {
            w.write(state);
            w.write('\n');
        } catch (Exception e) {
            Log.e(TAG, "writeState failed", e);
            return;
        }
        tmp.setReadable(true, false);
        tmp.setWritable(true, false);
        if (!tmp.renameTo(new File(MAP_DIR, STATE_FILE))) {
            Log.e(TAG, "writeState: rename failed");
        }
        Log.i(TAG, "state: " + state);
    }

    // attach and detach the uid audio mixes
    private boolean rebuild() {
        List<AudioMix> toDetach = new ArrayList<>();
        for (Map.Entry<Integer, AudioMix> e : new ArrayList<>(mAttached.entrySet())) {
            if (!mUidToBus.containsKey(e.getKey())) {
                toDetach.add(e.getValue());
                mAttached.remove(e.getKey());
            }
        }
        Map<Integer, AudioMix> added = new LinkedHashMap<>();
        for (Map.Entry<Integer, String> entry : mUidToBus.entrySet()) {
            if (mAttached.containsKey(entry.getKey())) {
                continue;
            }
            AudioMix mix = buildMix(entry.getKey(), entry.getValue());
            if (mix != null) {
                added.put(entry.getKey(), mix);
            }
        }
        if (toDetach.isEmpty() && added.isEmpty()) {
            return mPolicy != null || mUidToBus.isEmpty();
        }

        if (mPolicy == null) {
            if (added.isEmpty()) {
                return false;
            }
            AudioPolicy.Builder policyBuilder = new AudioPolicy.Builder(this);
            for (AudioMix mix : added.values()) {
                policyBuilder.addMix(mix);
            }
            AudioPolicy policy = policyBuilder.build();
            if (!register(policy)) {
                return false;
            }
            mPolicy = policy;
            mAttached.putAll(added);
            Log.i(TAG, "registered policy with " + added.size() + " uid mix(es)");
            return true;
        }

        if (!toDetach.isEmpty() && mPolicy.detachMixes(toDetach) != 0) {
            Log.e(TAG, "detachMixes failed");
        }
        if (!added.isEmpty()) {
            if (mPolicy.attachMixes(new ArrayList<>(added.values())) != 0) {
                Log.e(TAG, "attachMixes failed for " + added.keySet());
                return false;
            }
            mAttached.putAll(added);
            Log.i(TAG, "attached " + added.size() + " new uid mix(es)");
        }
        return true;
    }

    // build an audio mix routing a uid to the output bus device
    private AudioMix buildMix(int uid, String bus) {
        AudioDeviceInfo device = findBusDevice(bus);
        if (device == null) {
            Log.e(TAG, "no output device with address " + bus);
            return null;
        }
        AudioMixingRule rule = new AudioMixingRule.Builder()
                .addMixRule(AudioMixingRule.RULE_MATCH_UID, Integer.valueOf(uid))
                .build();
        AudioFormat format = new AudioFormat.Builder()
                .setSampleRate(48000)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build();
        return new AudioMix.Builder(rule)
                .setFormat(format)
                .setRouteFlags(AudioMix.ROUTE_FLAG_RENDER)
                .setDevice(device)
                .build();
    }

    // register the AudioPolicy with AudioManager
    private boolean register(AudioPolicy policy) {
        try {
            Method register = AudioManager.class.getMethod("registerAudioPolicy",
                    Class.forName("android.media.audiopolicy.AudioPolicy"));
            int status = (Integer) register.invoke(mAudioManager, policy);
            if (status != 0) {
                Log.e(TAG, "registerAudioPolicy failed, status " + status);
                return false;
            }
            return true;
        } catch (Exception e) {
            Log.e(TAG, "registerAudioPolicy threw", e);
            return false;
        }
    }

    // unregister the audio policy and clear the attached mixes
    private void unregister() {
        if (mPolicy == null) {
            return;
        }
        try {
            Method unregister = AudioManager.class.getMethod("unregisterAudioPolicy",
                    Class.forName("android.media.audiopolicy.AudioPolicy"));
            unregister.invoke(mAudioManager, mPolicy);
        } catch (Exception e) {
            Log.e(TAG, "unregisterAudioPolicy threw", e);
        }
        mPolicy = null;
        mAttached.clear();
    }

    // return the bus output device with the given address
    private AudioDeviceInfo findBusDevice(String address) {
        for (AudioDeviceInfo device : mAudioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            if (device.getType() == AudioDeviceInfo.TYPE_BUS
                    && address.equals(device.getAddress())) {
                return device;
            }
        }
        return null;
    }
}
