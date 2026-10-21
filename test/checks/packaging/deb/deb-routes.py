#!/usr/bin/env python3
import glob
import importlib.util
import os
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
AFFECTS = os.path.join(ROOT, "test", "system", "run", "affects.tsv")
TEST = "installer.sh"
SKIP_DIRS = (".git", "__pycache__")
ALLOWED_UNPARSED_LINES = {
    "for f in $(GFX_HAL_FILES); do cp -p $(GFX_HAL_DIR)/$$f $(PAYLOAD)/gfx_hal/; done",
    "for f in $(GFX_HAL_32_FILES); do cp -p var/share/gfx_hal_32/$$f $(PAYLOAD)/gfx_hal_32/; done",
    "python3 tools/build/packaging/deb/gen-rhizo-icon.py          debian/rhizo/usr/share/icons/hicolor/256x256/apps/rhizo.png",
    "echo '$(shell dpkg-parsechangelog -SVersion)' > $(PAYLOAD)/VERSION",
}


def load_check_package_tree():
    """return the package tree checker module loaded from its file"""
    spec = importlib.util.spec_from_file_location("check_package_tree", os.path.join(HERE, "..", "..", "lib", "package-tree.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_test_cache():
    """return the system test cache module loaded from its file"""
    spec = importlib.util.spec_from_file_location("test_affects_for_routes", os.path.join(ROOT, "test", "system", "run", "affects.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_stamps():
    """return the build stamps module loaded from its file"""
    spec = importlib.util.spec_from_file_location("stamps_for_routes", os.path.join(ROOT, "tools", "build", "stamps.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_payload_producers():
    """return the payload producers module loaded from its file"""
    spec = importlib.util.spec_from_file_location("payload_producers_for_routes", os.path.join(HERE, "..", "..", "build", "payload-producers.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def shipped_sources(cpt, rules_text, root):
    """return the install sources in debian/rules"""
    out = set()
    for sources, dest in cpt.copy_commands(rules_text):
        if not dest.startswith(cpt.STAGE):
            continue
        for s in sources:
            if "$(" in s:
                continue
            for p in sorted(glob.glob(os.path.join(root, s))):
                out.add(os.path.relpath(p, root))
    return out


def unparsed_recipe_lines(cpt, rules_text):
    """return the install recipe lines that could not be parsed"""
    out = []
    for line in cpt.install_recipe(rules_text):
        stripped = line.strip()
        if not stripped or stripped in ALLOWED_UNPARSED_LINES:
            continue
        if "$$" in line:
            out.append(line)
            continue
        words = shlex.split(line)
        if not words:
            continue
        if words[0] == "chmod":
            continue
        if words[0] not in ("install", "cp"):
            out.append(line)
            continue
        args, dirs_only, unknown_flag, i = [], False, False, 1
        while i < len(words):
            w = words[i]
            if w == "-m":
                i += 2
                continue
            if w == "-d":
                dirs_only = True
            elif w in ("-D", "-a"):
                pass
            elif w.startswith("-"):
                unknown_flag = True
            else:
                args.append(w)
            i += 1
        if unknown_flag:
            out.append(line)
        elif not dirs_only and len(args) < 2:
            out.append(line)
    return out


def ship_set_unrouted(pp, sf, system_cache, rules_path, artifacts_path, affects_tsv=None, test=TEST):
    """return the ship set entries no system test routes"""
    rows = system_cache.load_affects(affects_tsv or AFFECTS)
    ship = pp.packaged(rules_path)
    prods = pp.produced(artifacts_path)
    scripts = pp.producer_map(artifacts_path)
    staged = {name: sources for name, _build, sources in sf.rows(artifacts_path)}
    findings = []
    for p in sorted(ship):
        covered = pp.covered_by(p, prods)
        sources = None
        if covered is not None:
            rel = covered[len("var/share/"):] if covered.startswith("var/share/") else covered
            sources = staged.get(rel)
            if sources is None and covered in scripts:
                sources = [scripts[covered]]
        if sources is None:
            findings.append("%s: packaged under var/share/ with no producer in artifacts.tsv" % p)
            continue
        for s in sources:
            if not system_cache.path_is_input(s, test, rows):
                findings.append("%s: producer source %s does not route to %s" % (p, s, test))
    return sorted(set(findings))


def unrouted(cpt, system_cache, rules_text, root, affects_tsv=None, test=TEST):
    """return the shipped files no system test routes"""
    rows = system_cache.load_affects(affects_tsv or AFFECTS)
    findings = []
    for rel in sorted(shipped_sources(cpt, rules_text, root)):
        abspath = os.path.join(root, rel)
        if os.path.isdir(abspath):
            for dirpath, dirnames, filenames in os.walk(abspath):
                dirnames[:] = [d for d in sorted(dirnames) if d not in SKIP_DIRS]
                for fn in sorted(filenames):
                    p = os.path.relpath(os.path.join(dirpath, fn), root)
                    if not system_cache.path_is_input(p, test, rows):
                        findings.append(p)
        elif not system_cache.path_is_input(rel, test, rows):
            findings.append(rel)
    return sorted(set(findings))


def selftest():
    """test unrouted and ship_set_unrouted on fixtures"""
    import shutil
    import tempfile
    cpt = load_check_package_tree()
    system_cache = load_test_cache()
    tmp = tempfile.mkdtemp(prefix="check-deb-routes-")
    try:
        root = os.path.join(tmp, "tree")
        os.makedirs(os.path.join(root, "src", "install"))
        os.makedirs(os.path.join(root, "src", "services", "netbridged"))
        with open(os.path.join(root, "src", "install", "routed.sh"), "w") as f:
            f.write("echo one\n")
        with open(os.path.join(root, "src", "install", "unrouted.sh"), "w") as f:
            f.write("echo two\n")
        with open(os.path.join(root, "src", "services", "netbridged", "nb_one.py"), "w") as f:
            f.write("one\n")
        with open(os.path.join(root, "src", "services", "netbridged", "nb_two.py"), "w") as f:
            f.write("two\n")
        rules = """\
PAYLOAD := debian/rhizo/usr/lib/rhizo
%:
\tdh $@
override_dh_auto_install:
\tinstall -d $(PAYLOAD)
\tinstall -m 0755 src/install/routed.sh src/install/unrouted.sh $(PAYLOAD)/
\tcp -a src/services/netbridged $(PAYLOAD)/netbridged
"""
        affects = os.path.join(tmp, "affects.tsv")
        with open(affects, "w") as f:
            f.write("src/install/routed.sh\tinstaller.sh,network.sh\n")
            f.write("src/install/unrouted.sh\tnetwork.sh\n")
            f.write("src/services/netbridged/\tnetwork.sh\n")

        got = unrouted(cpt, system_cache, rules, root, affects_tsv=affects)
        want = ["src/install/unrouted.sh", "src/services/netbridged/nb_one.py", "src/services/netbridged/nb_two.py"]
        assert got == want, "expected the unrouted shipped paths named by themselves, got %r" % got

        with open(affects, "w") as f:
            f.write("src/install/routed.sh\tinstaller.sh,network.sh\n")
            f.write("src/install/unrouted.sh\tnetwork.sh\n")
            f.write("src/services/netbridged/\tnetwork.sh,installer.sh\n")
        got = unrouted(cpt, system_cache, rules, root, affects_tsv=affects)
        assert got == ["src/install/unrouted.sh"], \
            "routing src/services/netbridged/ to installer.sh should have cleared it, got %r" % got

        with open(affects, "w") as f:
            f.write("src/install/routed.sh\tinstaller.sh,network.sh\n")
            f.write("src/install/unrouted.sh\tnetwork.sh,installer.sh\n")
            f.write("src/services/netbridged/\tnetwork.sh,installer.sh\n")
        got = unrouted(cpt, system_cache, rules, root, affects_tsv=affects)
        assert got == [], "a fully routed ship set was still reported unrouted: %r" % got

        with open(affects, "w") as f:
            f.write("src/install/routed.sh\tinstaller.sh,network.sh\n")
            f.write("src/install/unrouted.sh\tALL\n")
            f.write("src/services/netbridged/\tALL\n")
        got = unrouted(cpt, system_cache, rules, root, affects_tsv=affects)
        assert got == [], "an ALL row was reported unrouted: %r" % got

        renamed = rules.replace("override_dh_auto_install:", "override_dh_install:")
        assert shipped_sources(cpt, renamed, root) == set(), \
            "a renamed override target should leave shipped_sources empty"

        victim = "src/install/routed.sh"
        install_t = rules.replace(
            "\tinstall -m 0755 src/install/routed.sh src/install/unrouted.sh $(PAYLOAD)/\n",
            "\tinstall -m 0755 src/install/routed.sh src/install/unrouted.sh $(PAYLOAD)/\n"
            "\tinstall -m 0755 -t $(PAYLOAD)/tools %s\n" % victim,
        )
        assert install_t != rules
        unparsed = unparsed_recipe_lines(cpt, install_t)
        assert any("-t" in l for l in unparsed), \
            "an install -t line should be reported as unparseable, got %r" % unparsed
        assert unparsed_recipe_lines(cpt, rules) == [], \
            "the fixture's own recipe was reported unparseable: %r" % unparsed_recipe_lines(cpt, rules)

        allow_rules = rules.replace(
            "\tcp -a src/services/netbridged $(PAYLOAD)/netbridged\n",
            "\tcp -a src/services/netbridged $(PAYLOAD)/netbridged\n"
            "\t" + next(iter(ALLOWED_UNPARSED_LINES)) + "\n",
        )
        assert unparsed_recipe_lines(cpt, allow_rules) == [], \
            "an allowlisted line was reported unparseable: %r" % unparsed_recipe_lines(cpt, allow_rules)

        pp = load_payload_producers()
        sf = load_stamps()
        share = os.path.join(root, "var", "share")
        os.makedirs(share)
        with open(os.path.join(share, "routed.bin"), "w") as f:
            f.write("r\n")
        with open(os.path.join(share, "elsewhere.bin"), "w") as f:
            f.write("e\n")
        with open(os.path.join(share, "orphan.bin"), "w") as f:
            f.write("o\n")
        ship_rules = os.path.join(tmp, "rules")
        with open(ship_rules, "w") as f:
            f.write("print-ship-set:\n\t@printf '%s\\n' var/share/routed.bin var/share/elsewhere.bin var/share/orphan.bin\n")
        with open(affects, "w") as f:
            f.write("tools/build/routed.sh\tinstaller.sh\n")
            f.write("tools/build/elsewhere.sh\tnetwork.sh\n")

        table = os.path.join(tmp, "artifacts.tsv")
        with open(table, "w") as f:
            f.write("routed.bin\ttools/build/routed.sh\ttools/build/routed.sh\tpayload\t-\n"
                    "elsewhere.bin\ttools/build/elsewhere.sh\ttools/build/elsewhere.sh\tpayload\t-\n")
        got = ship_set_unrouted(pp, sf, system_cache, ship_rules, table, affects_tsv=affects)
        assert any("var/share/orphan.bin" in f and "no producer" in f for f in got), \
            "a ship-set entry with no producer was not reported: %r" % got
        assert any("var/share/elsewhere.bin" in f and "does not route" in f for f in got), \
            "a fixture binary whose producer source routes elsewhere was not reported: %r" % got
        assert not any("var/share/routed.bin" in f for f in got), \
            "a correctly routed ship-set entry was reported: %r" % got

        with open(table, "w") as f:
            f.write("routed.bin\ttools/build/routed.sh\ttools/build/routed.sh\tpayload\t-\n"
                    "elsewhere.bin\ttools/build/elsewhere.sh\ttools/build/routed.sh\tpayload\t-\n")
        got = ship_set_unrouted(pp, sf, system_cache, ship_rules, table, affects_tsv=affects)
        assert not any("var/share/elsewhere.bin" in f for f in got), \
            "a artifacts.tsv row naming a routed source was still reported: %r" % got
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("check-deb-routes selftest: a shipped file or a file under a shipped directory with no "
          "installer.sh route is named by itself, and clears once routed (directly or via ALL); "
          "an empty or unparseable install recipe fails; a var/share/ ship-set entry with no producer "
          "or an unrouted producer source is named by itself")
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    cpt = load_check_package_tree()
    system_cache = load_test_cache()
    pp = load_payload_producers()
    sf = load_stamps()
    rules_path = os.path.join(ROOT, "debian", "rules")
    with open(rules_path) as f:
        rules = f.read()

    ok = True

    sources = shipped_sources(cpt, rules, ROOT)
    if not sources:
        print("FAIL: debian/rules' install recipe named no tracked or built source at all")
        ok = False

    for line in unparsed_recipe_lines(cpt, rules):
        print("FAIL: install recipe line could not be read as a copy command: %s" % line.strip())
        ok = False

    findings = unrouted(cpt, system_cache, rules, ROOT)
    for p in findings[:20]:
        print("FAIL: %s ships in the deb but affects.tsv does not route it to %s" % (p, TEST))
    if len(findings) > 20:
        print("FAIL: ... and %d more" % (len(findings) - 20))
    ok = ok and not findings

    ship_findings = ship_set_unrouted(pp, sf, system_cache, rules_path, sf.TABLE)
    for f in ship_findings[:20]:
        print("FAIL: %s" % f)
    if len(ship_findings) > 20:
        print("FAIL: ... and %d more" % (len(ship_findings) - 20))
    ok = ok and not ship_findings

    if not ok:
        return 1
    print("check-deb-routes: every file debian/rules ships, and every var/share/ artifact it requires, routes to %s" % TEST)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
