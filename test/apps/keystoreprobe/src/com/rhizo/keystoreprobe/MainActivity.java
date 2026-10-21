package com.rhizo.keystoreprobe;

import android.app.Activity;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyInfo;
import android.security.keystore.KeyProperties;
import android.security.keystore.KeyProtection;
import android.util.Log;
import android.widget.TextView;

import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;
import java.util.Arrays;

import javax.crypto.Mac;
import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

// activity for KeyMint system test probe
public class MainActivity extends Activity {
    private static final String TAG = "RhizoKeystoreProbe";
    private static final String ALIAS_EC = "rhizo-probe-ec";
    private static final String ALIAS_RSA = "rhizo-probe-rsa";
    private static final String ALIAS_HMAC = "rhizo-probe-hmac";
    private static final byte[] MESSAGE = "rhizo keystore probe".getBytes();

    private TextView tv;
    private int ok;
    private int failed;

    // show the title and run the probes on a thread
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        tv = new TextView(this);
        tv.setTextSize(28);
        tv.setTextColor(Color.WHITE);
        tv.setPadding(24, 24, 24, 24);
        tv.setText("RHIZO KEYSTORE PROBE\nrunning...");
        setContentView(tv);
        new Thread(new Runnable() {
            @Override
            public void run() {
                probe();
            }
        }).start();
    }

    // run the three KeyMint key operations
    private void probe() {
        final StringBuilder shown = new StringBuilder("RHIZO KEYSTORE PROBE\n");
        KeyStore ks = null;
        try {
            ks = KeyStore.getInstance("AndroidKeyStore");
            ks.load(null);
        } catch (Throwable t) {
            report("keystore_open", t);
            finish(shown);
            return;
        }
        for (String alias : new String[] {ALIAS_EC, ALIAS_RSA, ALIAS_HMAC}) {
            try { ks.deleteEntry(alias); } catch (Throwable ignored) { }
        }

        try {
            KeyPairGenerator kpg = KeyPairGenerator.getInstance(
                    KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore");
            kpg.initialize(new KeyGenParameterSpec.Builder(ALIAS_EC,
                    KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .build());
            KeyPair kp = kpg.generateKeyPair();
            signAndVerify(kp, "SHA256withECDSA");
            report("ec_p256_generate_sign_verify", securityLevel(kp.getPrivate()));
        } catch (Throwable t) {
            report("ec_p256_generate_sign_verify", t);
        }

        try {
            KeyPairGenerator kpg = KeyPairGenerator.getInstance(
                    KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore");
            kpg.initialize(new KeyGenParameterSpec.Builder(ALIAS_RSA,
                    KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
                    .setKeySize(2048)
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
                    .build());
            KeyPair kp = kpg.generateKeyPair();
            signAndVerify(kp, "SHA256withRSA");
            report("rsa_2048_generate_sign_verify", securityLevel(kp.getPrivate()));
        } catch (Throwable t) {
            report("rsa_2048_generate_sign_verify", t);
        }

        try {
            byte[] raw = new byte[32];
            for (int i = 0; i < raw.length; i++) raw[i] = (byte) (i * 7 + 3);
            SecretKey imported = new SecretKeySpec(raw, KeyProperties.KEY_ALGORITHM_HMAC_SHA256);
            ks.setEntry(ALIAS_HMAC, new KeyStore.SecretKeyEntry(imported),
                    new KeyProtection.Builder(KeyProperties.PURPOSE_SIGN).build());
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(ks.getKey(ALIAS_HMAC, null));
            byte[] tag = mac.doFinal(MESSAGE);
            Mac ref = Mac.getInstance("HmacSHA256");
            ref.init(imported);
            if (!Arrays.equals(tag, ref.doFinal(MESSAGE))) {
                throw new IllegalStateException("keystore HMAC differs from the software HMAC of the imported key");
            }
            report("hmac_sha256_import_mac", "");
        } catch (Throwable t) {
            report("hmac_sha256_import_mac", t);
        }

        for (String alias : new String[] {ALIAS_EC, ALIAS_RSA, ALIAS_HMAC}) {
            try { ks.deleteEntry(alias); } catch (Throwable ignored) { }
        }
        finish(shown);
    }

    // sign the test message and verify the signature
    private void signAndVerify(KeyPair kp, String algorithm) throws Exception {
        Signature s = Signature.getInstance(algorithm);
        s.initSign(kp.getPrivate());
        s.update(MESSAGE);
        byte[] sig = s.sign();
        Signature v = Signature.getInstance(algorithm);
        v.initVerify(kp.getPublic());
        v.update(MESSAGE);
        if (!v.verify(sig)) {
            throw new IllegalStateException(algorithm + " signature did not verify");
        }
    }

    // return the security level of the key
    private String securityLevel(PrivateKey key) {
        try {
            KeyFactory kf = KeyFactory.getInstance(key.getAlgorithm(), "AndroidKeyStore");
            KeyInfo info = kf.getKeySpec(key, KeyInfo.class);
            if (Build.VERSION.SDK_INT >= 31) {
                return "security_level=" + info.getSecurityLevel();
            }
            return "inside_secure_hardware=" + info.isInsideSecureHardware();
        } catch (Throwable t) {
            return "security_level=unknown(" + t.getClass().getSimpleName() + ")";
        }
    }

    // count and log a passed operation
    private void report(String op, String extra) {
        ok++;
        Log.i(TAG, "RHIZO_KEYSTORE_PROBE op=" + op + " result=ok" + (extra.isEmpty() ? "" : " " + extra));
    }

    // count and log a failed operation with its error and cause
    private void report(String op, Throwable t) {
        failed++;
        String msg = String.valueOf(t.getMessage()).replace('\n', ' ');
        Throwable cause = t.getCause();
        if (cause != null) {
            msg += " cause=" + cause.getClass().getSimpleName() + ": "
                    + String.valueOf(cause.getMessage()).replace('\n', ' ');
        }
        Log.e(TAG, "RHIZO_KEYSTORE_PROBE op=" + op + " result=fail err=" + t.getClass().getSimpleName() + ": " + msg);
    }

    // log the totals and color the screen by the result
    private void finish(final StringBuilder shown) {
        Log.i(TAG, "RHIZO_KEYSTORE_PROBE done ok=" + ok + " fail=" + failed);
        shown.append("ok=").append(ok).append(" fail=").append(failed);
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                tv.setBackgroundColor(failed == 0 ? Color.rgb(0, 96, 0) : Color.rgb(128, 0, 0));
                tv.setText(shown.toString());
            }
        });
    }
}
