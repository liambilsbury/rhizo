#!/usr/bin/env python3
import argparse
import os
import subprocess
import sys
import time


def main():
    """run the browser viewer stream proof"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--streamd", default=None)
    ap.add_argument("--export-test", default=None)
    ap.add_argument("--html", default=None)
    ap.add_argument("--render-node", default="/dev/dri/renderD128")
    ap.add_argument("--port", type=int, default=18701)
    ap.add_argument("--socket", default=None)
    ap.add_argument("--timeout", type=float, default=20.0)
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    streamd = args.streamd or os.path.join(repo, "var", "share", "rhizo-streamd")
    export_test = args.export_test or os.path.join(repo, "var", "share", "rhizo-stream-export-test")
    html = args.html or os.path.join(repo, "src", "services", "streamd", "viewer.html")
    sock = args.socket or "/tmp/rhizo-browser-proof.sock"

    if not (os.access(streamd, os.X_OK) and os.access(export_test, os.X_OK)):
        print("SKIP: rhizo-streamd or rhizo-stream-export-test is not built "
              "(tools/build/services/streamd.sh)", file=sys.stderr)
        return 2
    if not os.path.exists(args.render_node):
        print(f"SKIP: no render node at {args.render_node}", file=sys.stderr)
        return 2
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("SKIP: playwright is not installed (pip install playwright)", file=sys.stderr)
        return 2

    if os.path.exists(sock):
        os.remove(sock)
    streamd_proc = subprocess.Popen(
        [streamd, "--socket", sock, "--port", str(args.port),
         "--render-node", args.render_node, "--html", html],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        deadline = time.monotonic() + args.timeout
        while not os.path.exists(sock):
            if time.monotonic() > deadline:
                print("FAIL: rhizo-streamd never bound its socket", file=sys.stderr)
                return 3
            time.sleep(0.2)

        try:
            with sync_playwright() as p:
                try:
                    browser = p.chromium.launch()
                except Exception as e:
                    if "Executable doesn't exist" not in str(e):
                        print(f"FAIL: chromium.launch() failed: {e}", file=sys.stderr)
                        return 3
                    print(f"SKIP: playwright chromium is not installed "
                          f"(python3 -m playwright install chromium): {e}", file=sys.stderr)
                    return 2
                page = browser.new_page()
                page.goto(f"http://127.0.0.1:{args.port}/")

                export = subprocess.run(
                    [export_test, "--socket", sock, "--frames", "4",
                     "--size", "1280x800", "--render-node", args.render_node],
                    capture_output=True, text=True, timeout=args.timeout)
                if "RHIZO_STREAM_EXPORT_TEST_OK" not in export.stdout:
                    print(f"FAIL: the composer stand-in did not report success: "
                          f"{export.stdout} {export.stderr}", file=sys.stderr)
                    return 3

                page.wait_for_function("window.__rhizoStats.frames >= 1",
                                       timeout=int(args.timeout * 1000))
                stats = page.evaluate("window.__rhizoStats")
                browser.close()
        except Exception as e:
            print(f"FAIL: {e}", file=sys.stderr)
            return 3

        left, right = stats["left"], stats["right"]
        ok = left["r"] > 128 and left["b"] < 64 and right["b"] > 128 and right["r"] < 64
        print(f"RHIZO_BROWSER_PROOF_{'OK' if ok else 'MISMATCH'} frames={stats['frames']} "
              f"left_r={left['r']:.1f} left_b={left['b']:.1f} "
              f"right_r={right['r']:.1f} right_b={right['b']:.1f}")
        return 0 if ok else 1
    finally:
        streamd_proc.terminate()
        try:
            out, _ = streamd_proc.communicate(timeout=5)
            sys.stderr.write(out)
        except Exception:
            streamd_proc.kill()


if __name__ == "__main__":
    sys.exit(main())
