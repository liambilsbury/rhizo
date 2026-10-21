package com.rhizo.desktop;

import java.nio.charset.StandardCharsets;

// off-device test for HostClipEcho
public final class HostClipEchoTest {
    private static int failures;

    // print the result of a named check and count failures
    private static void check(String name, boolean ok) {
        System.out.println((ok ? "ok   " : "FAIL ") + name);
        if (!ok) failures++;
    }

    // return the UTF-8 bytes of a string
    private static byte[] b(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }

    // run the echo checks against HostClipEcho
    public static void main(String[] args) {
        String label = HostClipEcho.LABEL;

        HostClipEcho e = new HostClipEcho();
        e.hostSet("text/plain", b("rhizo-host-a"));
        check("the host's clip, reported back by its own change, is an echo",
                e.isEcho(label, "text/plain", b("rhizo-host-a")));

        e = new HostClipEcho();
        e.hostSet("text/plain", b("rhizo-host-a"));
        e.hostSet("image/png", b("rhizo-host-b"));
        check("two host clips in a row: the first change, reading the second, is an echo",
                e.isEcho(label, "image/png", b("rhizo-host-b")));
        check("an Android re-copy of the earlier host clip after the host moved on is not an echo",
                !e.isEcho(label, "text/plain", b("rhizo-host-a")));
        check("an app's own copy of the host's bytes under another label is not an echo",
                !e.isEcho("rhizo-deskapp", "image/png", b("rhizo-host-b")));
        check("an unlabeled copy is not an echo", !e.isEcho(null, "image/png", b("rhizo-host-b")));
        check("the same bytes under another mime are not an echo",
                !e.isEcho(label, "text/plain", b("rhizo-host-b")));

        if (failures > 0) {
            System.out.println(failures + " failure(s)");
            System.exit(1);
        }
        System.out.println("all passed");
    }
}
