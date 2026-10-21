package com.rhizo.desktop;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

// hello handshake for the host bridge
final class DeskAuth {
    private static final int NONCE_BYTES = 16;
    private static final int SHOWN_CHARS = 120;
    private static final Pattern CHALLENGE = Pattern.compile(
            "\\{\"t\":\"challenge\",\"nonce\":\"([0-9a-f]{32})\",\"proof\":\"([0-9a-f]{64})\"\\}");

    // forbid instances
    private DeskAuth() {}

    // line I/O for the bridge connection
    interface Lines {
        String read() throws IOException;

        void write(String line) throws IOException;
    }

    // exception for an unproven host
    static final class HostUnproven extends IOException {
        HostUnproven(String msg) {
            super(msg);
        }
    }

    // exchange token proofs with the host
    static void handshake(Lines io, String token, SecureRandom rng) throws IOException {
        byte[] raw = new byte[NONCE_BYTES];
        rng.nextBytes(raw);
        String androidNonce = hex(raw);
        io.write("{\"t\":\"hello\",\"nonce\":\"" + androidNonce + "\"}");
        String line = io.read();
        if (line == null) {
            throw new IOException("connection closed before the host's challenge");
        }
        Matcher m = CHALLENGE.matcher(line);
        if (!m.matches()) {
            throw new HostUnproven("no well-formed challenge: "
                    + line.substring(0, Math.min(line.length(), SHOWN_CHARS)));
        }
        String hostNonce = m.group(1);
        byte[] want = proof(token, "host", androidNonce, hostNonce).getBytes(StandardCharsets.US_ASCII);
        if (!MessageDigest.isEqual(want, m.group(2).getBytes(StandardCharsets.US_ASCII))) {
            throw new HostUnproven("the host's proof does not match this token");
        }
        io.write("{\"t\":\"auth\",\"proof\":\"" + proof(token, "android", androidNonce, hostNonce) + "\"}");
    }

    // return the HMAC-SHA256 proof for a role
    static String proof(String token, String role, String androidNonce, String hostNonce) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(token.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            String msg = "rhizo-desk " + role + "\n" + androidNonce + "\n" + hostNonce;
            return hex(mac.doFinal(msg.getBytes(StandardCharsets.US_ASCII)));
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("HmacSHA256 unavailable: " + e);
        }
    }

    // return the bytes as lowercase hex
    static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            out.append(Character.forDigit((b >> 4) & 0xf, 16)).append(Character.forDigit(b & 0xf, 16));
        }
        return out.toString();
    }
}
