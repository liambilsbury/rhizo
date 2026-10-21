#!/usr/bin/env python3
import base64
import importlib.util
import os
import shlex
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TRANSPORT_CAP = 16 << 20


def load_appsync():
    """return the appsync module loaded from its file"""
    spec = importlib.util.spec_from_file_location("rhizo_appsync", os.path.join(HERE, "..", "..", "..", "..", "src", "services", "appsync", "appsync.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def synthetic_apk(size):
    """return a synthetic apk of a size"""
    body = bytes((i * 7 + 13) & 0xFF for i in range(4096))
    data = b"PK\x03\x04" + body * (size // len(body) + 1)
    return data[:size]


def stub_backend(mod, apk_path, apk_bytes, calls):
    """return a host backend whose shell serves a synthetic apk"""
    class Stub(mod.HostBackend):
        def __init__(self):
            """start a local backend with a fixed init pid"""
            super().__init__(local=True, init_pid=4242)

        def android_sh(self, cmd, timeout=30):
            """answer stat and dd commands from the synthetic apk"""
            calls.append(cmd)
            words = shlex.split(cmd.split("|")[0])
            if words[:3] == ["stat", "-c", "%s"] and words[3] == apk_path:
                return str(len(apk_bytes))
            if words and words[0] == "dd":
                args = dict(w.split("=", 1) for w in words[1:] if "=" in w)
                if args.get("if") != apk_path:
                    return f"dd: {args.get('if')}: No such file or directory"
                bs, skip, count = int(args["bs"]), int(args.get("skip", 0)), int(args.get("count", 1))
                raw = apk_bytes[bs * skip: bs * (skip + count)]
            elif words == ["base64", apk_path]:
                raw = apk_bytes
            else:
                return f"sh: unexpected command: {cmd}"
            text = base64.encodebytes(raw).decode()
            return text[:TRANSPORT_CAP]
    return Stub()


def pull_once(mod, size):
    """pull a synthetic apk through the stub shell"""
    apk_path = "/data/app/~~fixture==/org.example.large-fixture==/base.apk"
    apk_bytes = synthetic_apk(size)
    calls = []
    backend = stub_backend(mod, apk_path, apk_bytes, calls)
    with tempfile.TemporaryDirectory() as work:
        local = os.path.join(work, "pulled.apk")
        ok, reason = backend.pull_via_shell(apk_path, local)
        same = ok and os.path.exists(local) and open(local, "rb").read() == apk_bytes
    return ok, reason, same, len(calls)


SIZES = (("a small APK", 64 << 10), ("an APK larger than one call carries", 40 << 20))


def findings(mod):
    """return the problems for the apk sizes that do not pull intact"""
    out = []
    for label, size in SIZES:
        ok, reason, same, _calls = pull_once(mod, size)
        if not ok:
            out.append("%s (%d bytes) did not pull: %s" % (label, size, (reason or "")[:160]))
        elif not same:
            out.append("%s (%d bytes) pulled, but its bytes differ from the APK" % (label, size))
    return out


def selftest():
    """mutate PULL_CHUNK_BYTES and run the pull check"""
    mod = load_appsync()
    chunk = getattr(mod, "PULL_CHUNK_BYTES", None)
    if not isinstance(chunk, int) or chunk <= 0:
        print("SELFTEST FAILED: appsync.py has no positive PULL_CHUNK_BYTES to mutate", file=sys.stderr)
        return 1
    if findings(mod):
        print("SELFTEST FAILED: the real pull was flagged: %s" % findings(mod), file=sys.stderr)
        return 1
    print("selftest ok: a small APK and one larger than a call carries both pull byte for byte")
    mod.PULL_CHUNK_BYTES = 64 << 20
    flagged = findings(mod)
    if not any("larger than one call carries" in f for f in flagged):
        print("SELFTEST FAILED: a pull that sends the whole large APK in one call was not caught (%s)" % flagged,
              file=sys.stderr)
        return 1
    print("selftest ok: catches a pull that asks one call for more than the transport carries")
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:2] == ["--selftest"]:
        return selftest()
    found = findings(load_appsync())
    if found:
        print("check-appsync-large-pull: rhizo-appsync cannot pull an installed APK through the sandbox shell:")
        for line in found:
            print("  " + line)
        return 1
    print("check-appsync-large-pull: an installed APK of any size pulls through the sandbox shell byte for byte")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
