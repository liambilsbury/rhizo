#!/usr/bin/env python3
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
REDEPLOY = os.path.join(REPO, "test", "vm", "redeploy.sh")
RELEASE_MAP = os.path.join(REPO, "test", "vm", "image", "release-map.sh")
HELPER = os.path.join(REPO, "test", "vm", "image", "guest-derive-tree.sh")
FETCH = os.path.join(REPO, "src", "install", "prepare", "fetch-gsi.sh")
DERIVE_PATCHES = os.path.join(REPO, "src", "install", "prepare", "derive-patches.sh")
LAUNCHER_DIR = os.path.join(REPO, "src", "androidd")
BESIDE_PATHS = os.path.join(REPO, "test", "checks", "packaging", "layout", "launcher-beside-paths.py")

FUNCTION = "derive_booting_tree_set"
LAUNCH_BLOCK = 'if [[ "$DO_LAUNCH" != 0 && -n "$GSI_PATH" ]]; then\n'
LAUNCH_END = '  log "Booting GSI tree: $GSI_PATH"\n'
CALL = "  %s || exit 1\n" % FUNCTION
LAUNCH_ENV = '  LAUNCH_ENV+="RHIZO_GSI=$GSI_PATH "\n'
PREDICATE = 'staged_set_is_of_tree "$RELEASE" "$GSI_PATH" && return 0\n'
HELPER_LOOP = "for kind in gsi_libs patches"
HELPER_VERDICT = '|| die "after the derive, $seen"'

CASES = (
    ("the userdebug tree with no release", "gsi_system_userdebug", "", True),
    ("the userdebug tree as release a16", "gsi_system_userdebug", "a16", True),
    ("the default tree", "gsi_system", "", False),
    ("the a17 tree as release a17", "gsi_system_a17", "a17", False),
)
TYPES = {"gsi_system": "user", "gsi_system_userdebug": "userdebug", "gsi_system_a17": "user"}

VIEW = """
import json, os, sys
sys.path.insert(0, sys.argv[1])
from sandbox import core
print(json.dumps({
    "props": core.product_build_prop_source(),
    "patches": core.stock_patches_dir(),
    "libs": core.gsi_libs_dir(),
    "missing": [os.path.basename(m) for m in core.gsi_derived_missing()],
    "mismatch": core.gsi_derived_mismatch(),
}))
"""

DRIVER = r"""set -uo pipefail
log() { echo "LOG $*"; }
ssh_vm() { if [[ "${1:-}" == -t ]]; then shift 2; fi; $AS_ROOT bash -c "$*"; }
source "$RELEASE_MAP_PATH"
for release in "${!GSI_DIR[@]}"; do GSI_DIR[$release]="${GSI_DIR[$release]/#\/srv\/rhizo/$SRV}"; done
source ./function.sh
%s
echo "RC=$?"
""" % FUNCTION


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def write(path, text):
    """write text to a file, making its folder"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def beside_paths():
    """load the beside paths check"""
    spec = importlib.util.spec_from_file_location("check_launcher_beside_paths", BESIDE_PATHS)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def lifted(text, name):
    """return a shell function's text, or None"""
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), text, re.M | re.S)
    return m.group(0) if m else None


def static_problems(redeploy_text):
    """return the problems with the derive step's place"""
    if lifted(redeploy_text, FUNCTION) is None:
        return ["redeploy.sh defines no %s()" % FUNCTION]
    bad = []
    if "\nsource ./image/release-map.sh\n" not in redeploy_text:
        bad.append("redeploy.sh never sources image/release-map.sh")
    start = redeploy_text.find("\n" + LAUNCH_BLOCK)
    end = redeploy_text.find(LAUNCH_END, start) if start >= 0 else -1
    if start < 0 or end < 0:
        return bad + ["redeploy.sh has no GSI tree launch block this check can read"]
    block = redeploy_text[start:end]
    call, env = block.find(CALL), block.find(LAUNCH_ENV)
    if call < 0:
        bad.append("redeploy.sh never calls %s in the block that boots --gsi" % FUNCTION)
    elif env < 0 or call > env:
        bad.append("redeploy.sh calls %s after it names the tree in the launch environment" % FUNCTION)
    return bad


class Rig:
    """scratch guest with the default staged set"""

    def __init__(self, tmp, lab, prefix):
        """build the trees and the staged set"""
        self.tmp, self.prefix = tmp, prefix
        self.srv = os.path.join(tmp, "srv")
        self.root = os.path.join(tmp, "root")
        self.derived = os.path.join(tmp, "derived")
        self.names = lab.fetch_lib_names(read(FETCH))
        self.trees = {}
        for name, kind in TYPES.items():
            release = "a17" if name.endswith("a17") else "a16"
            tree = lab.scratch_tree(self.srv, name, "rhizo/%s:%s" % (release, kind), self.names)
            write(os.path.join(tree, "product", "etc", "build.prop"),
                  "# tree %s\nro.product.build.type=%s\nro.build.type=%s\n" % (name, kind, kind))
            for service in ("cameraserver", "wificond"):
                write(os.path.join(tree, "etc", "init", "%s.rc" % service),
                      "# tree %s\nservice %s /system/bin/%s\n    class main\n" % (name, service, service))
            self.trees[name] = tree
        os.makedirs(self.root)
        for module in os.listdir(LAUNCHER_DIR):
            if module.endswith(".py"):
                shutil.copy(os.path.join(LAUNCHER_DIR, module), self.root)
        shutil.copytree(os.path.join(LAUNCHER_DIR, "sandbox"), os.path.join(self.root, "sandbox"),
                        ignore=shutil.ignore_patterns("__pycache__"))
        subprocess.run(self.prefix + ["bash", DERIVE_PATCHES, "a16", "--from-tree", self.trees["gsi_system"], "--out", self.root],
                       check=True, capture_output=True, timeout=120)
        for name in self.names:
            write(os.path.join(self.root, "share", "gsi_libs", name), read(os.path.join(self.trees["gsi_system"], "lib64", name)))

    def reset(self):
        """remove everything a deploy derived"""
        shutil.rmtree(self.derived, ignore_errors=True)

    def deploy(self, redeploy_text, release_map, helper, tree, release):
        """run the deploy step for a tree"""
        work = tempfile.mkdtemp(prefix="deploy-", dir=self.tmp)
        write(os.path.join(work, "function.sh"), lifted(redeploy_text, FUNCTION))
        write(os.path.join(work, "driver.sh"), DRIVER)
        os.makedirs(os.path.join(work, "image"))
        shutil.copy(helper, os.path.join(work, "image", "guest-derive-tree.sh"))
        env = dict(os.environ, RHIZO_DERIVED_DIR=self.derived, RHIZO_FETCH_GSI=FETCH, RHIZO_DERIVE_PATCHES=DERIVE_PATCHES,
                   RHIZO_LAUNCHER_DIR=self.root, AS_ROOT=" ".join(self.prefix), RELEASE_MAP_PATH=release_map, SRV=self.srv,
                   GSI_PATH=self.trees[tree], RELEASE=release)
        done = subprocess.run(["bash", "driver.sh"], cwd=work, env=env, capture_output=True, text=True, timeout=300)
        rc = re.findall(r"^RC=(\d+)$", done.stdout, re.M)
        return (int(rc[-1]) if rc else -1), done.stdout + done.stderr

    def view(self, tree):
        """return what the launcher reads for a tree"""
        env = dict(os.environ, RHIZO_GSI=self.trees[tree], RHIZO_DERIVED_DIR=self.derived)
        done = subprocess.run([sys.executable, "-c", VIEW, self.root], env=env, capture_output=True, text=True, timeout=60)
        if done.returncode != 0:
            return {"error": done.stderr[-300:]}
        return json.loads(done.stdout.strip().splitlines()[-1])


def own_set_problems(rig, label, tree):
    """return the problems with a derived tree's set"""
    seen = rig.view(tree)
    if "error" in seen:
        return ["%s: the launcher could not be asked: %s" % (label, seen["error"])]
    bad = []
    own = os.path.join(rig.derived, "patches", tree)
    props = seen["props"]
    got = re.findall(r"^ro\.build\.type=(\S+)$", read(props), re.M) if props and os.path.isfile(props) else []
    if props != os.path.join(own, "product-build.prop") or got != [TYPES[tree]]:
        bad.append("%s: the launcher stages %s (ro.build.type=%s) as the product build.prop, not its own derived copy "
                   "(ro.build.type=%s)" % (label, props, ",".join(got) or "none", TYPES[tree]))
    if seen["patches"] != own:
        bad.append("%s: the launcher reads stock patches from %s, not %s" % (label, seen["patches"], own))
    netd = os.path.join(own, "netd.rc")
    first = read(netd).splitlines()[0] if os.path.isfile(netd) else "<missing>"
    if first != "# tree %s" % tree:
        bad.append("%s: the staged netd.rc starts %r, not with the tree's own marker" % (label, first))
    libs = os.path.join(rig.derived, "gsi_libs", tree)
    if seen["libs"] != libs or seen["missing"] or seen["mismatch"]:
        bad.append("%s: the launcher reads libraries from %s (missing %s, mismatch %s), not the tree's own %s"
                   % (label, seen["libs"], seen["missing"], seen["mismatch"], libs))
    else:
        foreign = [n for n in rig.names if read(os.path.join(libs, n)) != read(os.path.join(rig.trees[tree], "lib64", n))]
        if foreign:
            bad.append("%s: %d librar(ies) in %s differ from the tree's, e.g. %s" % (label, len(foreign), libs, foreign[0]))
    return bad


def case_problems(rig, label, tree, release, derives, redeploy_text, release_map, helper):
    """return the problems with a deploy case"""
    rig.reset()
    rc, out = rig.deploy(redeploy_text, release_map, helper, tree, release)
    if rc != 0:
        return ["%s: the deploy step exited %d: %s" % (label, rc, out.strip()[-300:])]
    if not derives:
        bad = []
        seen = rig.view(tree)
        if os.path.isdir(rig.derived) and os.listdir(rig.derived):
            bad.append("%s: the deploy derived %s, though the tree is the one its release's staged files came from"
                       % (label, sorted(os.listdir(rig.derived))))
        if seen.get("props") != os.path.join(rig.root, "product-build.prop"):
            bad.append("%s: the launcher reads %s, not the staged product build.prop" % (label, seen.get("props", seen)))
        return bad
    bad = own_set_problems(rig, label, tree)
    if not bad:
        rc, out = rig.deploy(redeploy_text, release_map, helper, tree, release)
        if rc != 0:
            bad.append("%s: a second deploy of the same tree exited %d: %s" % (label, rc, out.strip()[-300:]))
        bad += own_set_problems(rig, label + " deployed twice", tree)
    leftovers = [n for n in os.listdir(rig.derived) if n.startswith(".")] if os.path.isdir(rig.derived) else []
    if leftovers:
        bad.append("%s: the deploy left %s in the derived folder" % (label, leftovers))
    return bad


def failure_problems(rig, redeploy_text, release_map, helper):
    """return the problems with an underivable tree"""
    tree = "gsi_system_userdebug"
    rig.reset()
    victim = rig.names[0]
    os.unlink(os.path.join(rig.trees[tree], "lib64", victim))
    rc, out = rig.deploy(redeploy_text, release_map, helper, tree, "")
    bad = []
    if rc == 0:
        bad.append("a tree missing %s deployed with exit 0" % victim)
    if victim not in out:
        bad.append("the deploy of a tree missing %s does not name the library: %s" % (victim, out.strip()[-300:]))
    if any(os.path.isdir(os.path.join(rig.derived, kind, tree)) for kind in ("patches", "gsi_libs")):
        bad.append("the deploy of a tree missing %s left a half derived set in %s" % (victim, rig.derived))
    return bad


def check(redeploy_text, release_map=RELEASE_MAP, helper=HELPER):
    """return the problems with a deploy's derived files"""
    bad = static_problems(redeploy_text)
    absent = lifted(redeploy_text, FUNCTION) is None
    if bad and not absent:
        return bad
    lab = beside_paths()
    prefix = lab.as_root()
    if prefix is None:
        return bad + ["cannot run the deploy step as root here: neither `unshare -r` nor fakeroot works"]
    with tempfile.TemporaryDirectory() as tmp:
        rig = Rig(tmp, lab, prefix)
        if absent:
            return bad + own_set_problems(rig, "a launch of the userdebug tree after a deploy with no such step", "gsi_system_userdebug")
        for label, tree, release, derives in CASES:
            bad += case_problems(rig, label, tree, release, derives, redeploy_text, release_map, helper)
        bad += failure_problems(rig, redeploy_text, release_map, helper)
    return bad


def selftest():
    """check the real inputs and each mutant"""
    fails = []
    redeploy, release_map, helper = read(REDEPLOY), read(RELEASE_MAP), read(HELPER)

    def expect(name, findings, needle):
        """record a failure unless the findings match"""
        hit = any(needle in f for f in findings)
        if needle and not hit:
            fails.append("%s: no finding naming %r in %r" % (name, needle, findings))
        if not needle and findings:
            fails.append("%s: flagged %r" % (name, findings))

    def edited(text, old, new):
        """return the text with old replaced"""
        if old not in text:
            fails.append("the anchor %r moved" % old.strip()[:60])
        return text.replace(old, new)

    with tempfile.TemporaryDirectory() as tmp:
        def variant(name, text):
            """write an edited script, returning its path"""
            path = os.path.join(tmp, name)
            write(path, text)
            return path

        expect("the real deploy", check(redeploy), "")
        old_deploy = check(edited(edited(redeploy, CALL, ""), lifted(redeploy, FUNCTION) or "<missing>", ""))
        expect("a deploy with no step deriving the booting tree's set", old_deploy, "defines no %s()" % FUNCTION)
        expect("a launch of the userdebug tree after a deploy with no such step", old_deploy,
               "(ro.build.type=user) as the product build.prop, not its own derived copy (ro.build.type=userdebug)")
        expect("a deploy that never calls the step", check(edited(redeploy, CALL, "")), "never calls %s" % FUNCTION)
        late = edited(edited(redeploy, CALL, ""), LAUNCH_ENV, LAUNCH_ENV + CALL)
        expect("a deploy that derives after naming the tree to the launcher", check(late), "calls %s after" % FUNCTION)
        expect("a deploy that never sources the release map",
               check(edited(redeploy, "\nsource ./image/release-map.sh\n", "\n")), "never sources image/release-map.sh")

        expect("a step that returns before deriving", check(edited(redeploy, PREDICATE, "return 0\n")),
               "not its own derived copy")
        expect("a step that derives only for a release's own tree",
               check(edited(redeploy, PREDICATE, PREDICATE.replace("&&", "||"))), "not its own derived copy")
        expect("a step that derives for a release's own tree too", check(edited(redeploy, PREDICATE, "")),
               "though the tree is the one")
        expect("a step that reports success when the derive failed",
               check(edited(redeploy, '    return 1\n  fi\n  log "  $(grep', '    return 0\n  fi\n  log "  $(grep')),
               "deployed with exit 0")

        predicate = '[[ "${2%/}" == "${GSI_DIR[${1:-a16}]:-}" ]]'
        expect("a release map that calls every tree the staged set's own",
               check(redeploy, variant("release-map-true.sh", edited(release_map, predicate, "true"))),
               "not its own derived copy")
        expect("a release map that calls no tree the staged set's own",
               check(redeploy, variant("release-map-false.sh", edited(release_map, predicate, "false"))),
               "though the tree is the one")

        unverified = edited(helper, HELPER_VERDICT, "|| true")
        no_libs = variant("helper-no-libs.sh", edited(unverified, HELPER_LOOP, "for kind in patches"))
        expect("a helper that leaves the libraries beside the launcher's default", check(redeploy, RELEASE_MAP, no_libs),
               "reads libraries from")
        no_patches = variant("helper-no-patches.sh", edited(unverified, HELPER_LOOP, "for kind in gsi_libs"))
        expect("a helper that leaves the stock patches beside the launcher's default", check(redeploy, RELEASE_MAP, no_patches),
               "not its own derived copy")
        wrong_name = variant("helper-wrong-name.sh", edited(helper, '"$DERIVED/$kind/$BASE" || die "cannot move the derived',
                                                            '"$DERIVED/$kind/gsi_system" || die "cannot move the derived'))
        expect("a helper that names the set for the default tree", check(redeploy, RELEASE_MAP, wrong_name),
               "the deploy step exited 1")
        unchecked = variant("helper-unchecked.sh", edited(helper, "RHIZO_GSI_DERIVED*) ;;", "*) ;;"))
        expect("a helper that carries on past a failed derive", check(redeploy, RELEASE_MAP, unchecked),
               "half derived set")

    for f in fails:
        print("SELFTEST FAIL: " + f)
    if fails:
        return 1
    print("deploy-tree-own-set selftest: every mutant flagged, the real deploy clean")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    bad = check(read(REDEPLOY))
    for b in bad:
        print("FAIL: " + b)
    if bad:
        return 1
    print("deploy-tree-own-set: a deploy of the userdebug tree, with or without a release, leaves the launcher reading that "
          "tree's own libraries, stock patches and product build.prop; the default tree and a release's own tree keep the "
          "staged set; a tree that cannot be derived fails the deploy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
