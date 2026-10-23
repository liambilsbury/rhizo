#!/usr/bin/env python3
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
from sandbox import core  # noqa: E402

REDEPLOY = os.path.join(REPO, "test", "vm", "redeploy.sh")
RELEASE_MAP = os.path.join(REPO, "test", "vm", "image", "release-map.sh")
RULES = os.path.join(REPO, "debian", "rules")
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")
HALS = os.path.join(REPO, "src", "androidd", "sandbox", "hals.py")
PACKAGE_LIB = "/usr/lib/rhizo"


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def _deploy_parity():
    """return the deploy layout parity module loaded from its file"""
    spec = importlib.util.spec_from_file_location("check_deploy_layout_parity",
                                                  os.path.join(HERE, "deploy-layout-parity.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def bash_array(text, name):
    """return the words of a bash array"""
    m = re.search(r"^%s=\((.*?)\)" % re.escape(name), text, re.M | re.S)
    if not m:
        return None
    return [w for w in re.sub(r"#[^\n]*", "", m.group(1)).split()]


def rig_release_hal_builds(release_map_text, hal_bins):
    """return each release with its HAL binary"""
    out = {}
    for rel, path in re.findall(r'^\s*\[(\w+)\]="share/rel/\1/([\w.-]+)"', release_map_text, re.M):
        if path in hal_bins:
            out[rel] = path
    return out


def check(redeploy_text, release_map_text, installed, launcher_text, hals_text,
          a16_only=core.A16_ONLY_PAYLOAD, skips=core.release_skips,
          hal_bin=core.release_hal_bin, beside=core.beside):
    """return the problems with the release file lists"""
    bad = []
    is_shipped = _deploy_parity()._is_shipped
    skip = bash_array(redeploy_text, "RELEASE_SKIP")
    hal_bins = bash_array(redeploy_text, "RELEASE_GFX_HAL_BIN")
    if skip is None or hal_bins is None:
        return ["redeploy.sh has no RELEASE_SKIP=( ) or RELEASE_GFX_HAL_BIN=( ) array to compare against"]

    shipped_skip = {f for f in skip if is_shipped("%s/%s" % (PACKAGE_LIB, f), installed)}
    for name in sorted(shipped_skip - set(a16_only)):
        bad.append("the .deb ships %s, which redeploy.sh leaves out of every non-a16 boot, and "
                   "core.A16_ONLY_PAYLOAD does not name it" % name)
    for name in sorted(set(a16_only) - shipped_skip):
        bad.append("core.A16_ONLY_PAYLOAD names %s, which is not a RELEASE_SKIP file the .deb "
                   "ships -- an unused row" % name)
    if bash_array(redeploy_text, "AUDIO_SET_RELEASES") != list(core.AUDIO_SET_RELEASES):
        bad.append("redeploy.sh's AUDIO_SET_RELEASES is not core.AUDIO_SET_RELEASES %r"
                   % (core.AUDIO_SET_RELEASES,))
    for name in sorted(a16_only):
        for rel in core.AUDIO_SET_RELEASES:
            if skips(name, rel):
                bad.append("release_skips(%r, %r) skips an audio-set release" % (name, rel))

    builds = rig_release_hal_builds(release_map_text, hal_bins)
    if not builds:
        bad.append("release-map.sh names no share/rel/<release>/ build of a RELEASE_GFX_HAL_BIN "
                   "binary")
    gfx = "/gfx_hal"
    for rel, name in sorted(builds.items()):
        own = beside("rel", rel, name)
        if not is_shipped("%s/rel/%s/%s" % (PACKAGE_LIB, rel, name), installed):
            bad.append("the rig stages %s's %s from share/rel/%s/, and the .deb ships no "
                       "%s/rel/%s/%s" % (rel, name, rel, PACKAGE_LIB, rel, name))
        got = hal_bin(gfx, name, rel, exists=lambda p: True)
        if got != own:
            bad.append("release_hal_bin for %s picks %s, not the shipped %s" % (rel, got, own))
        got = hal_bin(gfx, name, rel, exists=lambda p: False)
        if got != os.path.join(gfx, name):
            bad.append("release_hal_bin for %s with no rel/%s/ build picks %s, not gfx_hal/'s" % (rel, rel, got))
        got = hal_bin(gfx, name, "a16", exists=lambda p: True)
        if got != os.path.join(gfx, name):
            bad.append("release_hal_bin for a16 picks %s, not gfx_hal/'s %s" % (got, name))
        if not re.search(r'core\.release_hal_bin\(gfx_src, "%s"\)' % re.escape(name), hals_text):
            bad.append("sandbox/hals.py stages %s without asking core.release_hal_bin" % name)

    for name in sorted(a16_only):
        m = re.search(r'core\.release_skips\("%s"\).*?os\.path\.exists\(' % re.escape(name),
                      launcher_text, re.S)
        if not m or len(m.group(0)) > 400:
            bad.append("launcher3.py stages %s without asking core.release_skips first" % name)
    return bad


def real_inputs():
    """return the texts and installed paths read from the real tree"""
    rules = read(RULES)
    return (read(REDEPLOY), read(RELEASE_MAP), _deploy_parity().deb_installed_paths(rules),
            read(LAUNCHER), read(HALS))


def selftest():
    """check the real inputs and each planted-defect copy of them"""
    fails = []

    def expect(name, findings, needle):
        """check the findings name the needle"""
        hit = any(needle in f for f in findings)
        if needle and not hit:
            fails.append("%s: no finding naming %r in %r" % (name, needle, findings))
        if not needle and findings:
            fails.append("%s: flagged %r" % (name, findings))

    redeploy, release_map, installed, launcher, hals = real_inputs()
    expect("the real tree", check(redeploy, release_map, installed, launcher, hals), "")

    grown = redeploy.replace("RELEASE_SKIP=(com.android.tethering.apex",
                             "RELEASE_SKIP=(RhizoHome.apk com.android.tethering.apex", 1)
    if grown == redeploy:
        fails.append("the RELEASE_SKIP anchor moved")
    expect("a RELEASE_SKIP file the package ships and boots anyway",
           check(grown, release_map, installed, launcher, hals), "ships RhizoHome.apk")
    expect("an a16-only set that drops the router",
           check(redeploy, release_map, installed, launcher, hals,
                 a16_only=("audio_policy_configuration.xml",)), "ships RhizoAudioRouter.apk")
    expect("a release_skips that ignores the release",
           check(redeploy, release_map, installed, launcher, hals,
                 skips=lambda name, release=None: True), "skips an audio-set release")

    unshipped = {p for p in installed if "/rel/" not in p}
    expect("a package that does not ship a15's power HAL",
           check(redeploy, release_map, unshipped, launcher, hals), "the .deb ships no /usr/lib/rhizo/rel/a15/")
    expect("a release_hal_bin that always stages gfx_hal/'s",
           check(redeploy, release_map, installed, launcher, hals,
                 hal_bin=lambda g, n, r=None, exists=None: os.path.join(g, n)),
           "release_hal_bin for a15 picks /gfx_hal/rhizo-power-service")
    blind = hals.replace('core.release_hal_bin(gfx_src, "rhizo-power-service")',
                         'f"{gfx_src}/rhizo-power-service"', 1)
    if blind == hals:
        fails.append("the sandbox/hals.py power anchor moved")
    expect("a power HAL staged straight from gfx_hal/",
           check(redeploy, release_map, installed, launcher, blind), "without asking core.release_hal_bin")
    ungated = launcher.replace('core.release_skips("RhizoAudioRouter.apk")', "False", 1)
    if ungated == launcher:
        fails.append("the launcher router anchor moved")
    expect("a router staged on every release",
           check(redeploy, release_map, installed, ungated, hals),
           "stages RhizoAudioRouter.apk without asking")

    for f in fails:
        print("SELFTEST FAIL: " + f)
    if fails:
        return 1
    print("check-release-files selftest: every mutant flagged, the real tree clean")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    bad = check(*real_inputs())
    for b in bad:
        print("FAIL: " + b)
    if bad:
        return 1
    print("check-release-files: a packaged boot of each release stages what redeploy.sh --release "
          "stages for it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
