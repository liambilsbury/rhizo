#!/usr/bin/env python3
# check the current prepared tree against its manifest
import hashlib, json, os, subprocess, sys

root = sys.argv[1]
current = os.path.join(root, "current")
try:
    key = os.readlink(current)
except OSError as e:
    print(f"BAD: no readable 'current' symlink at {current}: {e}")
    sys.exit(1)
tree = os.path.join(root, key)
manifest_path = os.path.join(tree, "manifest.json")
try:
    manifest = json.load(open(manifest_path))
except (OSError, ValueError) as e:
    print(f"BAD: cannot read {manifest_path}: {e}")
    sys.exit(1)


def sha256_of(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


# return a file's selinux label
def label_of(path):
    try:
        out = subprocess.run(["getfattr", "-n", "security.selinux", "--only-values", path],
                              capture_output=True, text=True, check=False)
        return out.stdout.strip().strip("\x00")
    except OSError:
        return None


bad = 0
inputs = manifest.get("inputs", {})
outputs = manifest.get("outputs", {})
for src, meta in inputs.items():
    got = sha256_of(src)
    if got != meta.get("sha256"):
        print(f"BAD: input changed since prepare: {src}")
        bad = 1
for rel, meta in outputs.items():
    full = os.path.join(tree, rel)
    if meta.get("kind") == "dir":
        if not os.path.isdir(full):
            print(f"BAD: output directory missing: {rel}")
            bad = 1
        continue
    got = sha256_of(full)
    if got != meta.get("sha256"):
        print(f"BAD: output changed since prepare: {rel}")
        bad = 1
        continue
    want_label = meta.get("label")
    if want_label:
        got_label = label_of(full)
        if got_label and got_label != want_label:
            print(f"BAD: output relabeled since prepare: {rel} ({got_label} != {want_label})")
            bad = 1
if not bad:
    print(f"OK key={manifest.get('key', '?')} inputs={len(inputs)} outputs={len(outputs)}")
sys.exit(bad)
