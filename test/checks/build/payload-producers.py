#!/usr/bin/env python3
import importlib.util
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
RULES = os.path.join(ROOT, "debian", "rules")
MANIFEST = os.path.join(ROOT, "tools", "build", "artifacts.tsv")

BUILD_ONLY = {"var/share/gsi_libs", "var/share/gsi_libs_32",
              "var/share/rhizo-stream-export-test"}


def packaged(rules):
    """return the var/share paths debian/rules packages"""
    out = subprocess.run(["make", "-s", "-f", rules, "print-ship-set"],
                         cwd=os.path.dirname(rules), capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("make -f %s print-ship-set failed: %s" % (rules, out.stderr.strip()))
    return {p for p in out.stdout.split() if p.startswith("var/share/")}


def load_stamps():
    """return the build stamps module loaded from its file"""
    spec = importlib.util.spec_from_file_location("stamps_for_producers", os.path.join(ROOT, "tools", "build", "stamps.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def produced(manifest):
    """return the products the payload rows name"""
    st = load_stamps()
    return {st.product_path(e.name) for e in st.entries(manifest) if e.set == "payload"}


def producer_map(manifest):
    """map each product path to its build script"""
    st = load_stamps()
    return {st.product_path(e.name): e.build.split()[0] for e in st.entries(manifest) if e.set == "payload"}


def covered_by(path, products):
    """find the product for a path"""
    for p in products:
        if path == p or path.startswith(p + "/") or p.startswith(path + "/"):
            return p
    return None


def check(rules, payload):
    """find packaged files that no payload row produces"""
    ship = packaged(rules)
    prods = produced(payload)
    bad = []
    for p in sorted(ship):
        if covered_by(p, prods) is None:
            bad.append("packaged but no payload row in artifacts.tsv produces it: %s" % p)
    for q in sorted(prods):
        if not q.startswith("var/share/") or q in BUILD_ONLY:
            continue
        if q not in ship and not any(s.startswith(q + "/") for s in ship):
            bad.append("produced but debian/rules packages nothing of it: %s" % q)
    return bad


def selftest():
    """check a planted rules file and payload table"""
    fail = 0
    with tempfile.TemporaryDirectory() as tmp:
        rules = os.path.join(tmp, "rules")
        payload = os.path.join(tmp, "artifacts.tsv")
        with open(rules, "w") as f:
            f.write("REQUIRED_DIRS := var/share/gpu_driver\n"
                    "REQUIRED_FILES := var/share/aapt2 var/share/orphan.bin\n"
                    "print-ship-set:\n\t@printf '%s\\n' $(REQUIRED_DIRS) $(REQUIRED_FILES)\n")
        with open(payload, "w") as f:
            f.write("gpu_driver\ttools/build/x.sh\tsrc\tpayload\t-\n"
                    "gsi_libs\ttools/build/x.sh\tsrc\tpayload\t-\n"
                    "aapt2\ttools/build/y.sh --rebuild\tsrc\tpayload\t-\n"
                    "unpackaged\ttools/build/z.sh\tsrc\tpayload\t-\n"
                    "testonly.apk\ttools/build/z.sh\tsrc\ttest\t-\n")
        pm = producer_map(payload)
        if pm.get("var/share/aapt2") != "tools/build/y.sh":
            print("SELFTEST FAILED: producer_map lost the script for a product with build args: %s" % pm); fail = 1
        if pm.get("var/share/gpu_driver") != "tools/build/x.sh":
            print("SELFTEST FAILED: producer_map named the wrong script: %s" % pm); fail = 1
        bad = check(rules, payload)
        if not any("orphan.bin" in b and "no payload row" in b for b in bad):
            print("SELFTEST FAILED: a packaged path with no producer was not reported: %s" % bad); fail = 1
        if not any("unpackaged" in b and "packages nothing" in b for b in bad):
            print("SELFTEST FAILED: a product nothing packages was not reported: %s" % bad); fail = 1
        if any("gsi_libs" in b for b in bad):
            print("SELFTEST FAILED: a declared build-only product was reported: %s" % bad); fail = 1
        if any("testonly" in b for b in bad):
            print("SELFTEST FAILED: a test row was reported as a payload product: %s" % bad); fail = 1
        if any("gpu_driver" in b or "aapt2" in b for b in bad):
            print("SELFTEST FAILED: a matched pair was reported: %s" % bad); fail = 1
    if fail:
        print("payload-producers.py selftest: FAILED")
        return 1
    print("payload-producers.py selftest: ok")
    return 0


def main(argv):
    """run the check or its selftest and print the result"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: payload-producers.py [--selftest]", file=sys.stderr)
        return 2
    bad = check(RULES, MANIFEST)
    for b in bad:
        print(b, file=sys.stderr)
    if bad:
        return 1
    print("check-payload-producers: every packaged var/share path has a producer and every product is packaged")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
