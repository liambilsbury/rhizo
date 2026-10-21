#!/usr/bin/env python3
"""Check that each instance's uinput devices carry their phys prefix."""
import contextlib
import io
import os
import re
import sys
import xml.etree.ElementTree as ET

USAGE = """Usage: input-port-fence.py [--selftest]"""

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

UINPUT = os.path.join(ROOT, "src", "android", "hal", "graphics-composer", "src", "input", "uinput.cpp")
HALS = os.path.join(ROOT, "src", "androidd", "sandbox", "hals.py")
LAUNCHER = os.path.join(ROOT, "src", "androidd", "boot.py")
RC = os.path.join(ROOT, "src", "androidd", "guest", "init", "composer.rc")

LEGACY_DESKTOP_XML = (
    '<?xml version="1.0" encoding="utf-8"?>\n<ports>\n'
    + "".join(f'    <port display="{n}" input="rhizo-port-{n}" />\n' for n in range(0, 9))
    + "</ports>\n")


def associations(text):
    """return the phys table and repeated phys"""
    table, dupes = {}, []
    for port in ET.fromstring(text).iter("port"):
        phys, display = port.get("input"), int(port.get("display"))
        if phys in table:
            dupes.append(phys)
        table[phys] = display
    return table, dupes


def check_associations(prefix_fn, xml_fn, max_id, ports, fenced):
    """check the phys prefix and XML builder"""
    bad = []
    everyone = {prefix_fn(i) + str(n) for i in range(max_id + 1) for n in ports}
    if len(everyone) != (max_id + 1) * len(ports):
        bad.append(("PREFIX-COLLISION",
                    "two instances give a device the same phys"))
    if fenced in ports:
        bad.append(("FENCE-IS-A-PORT",
                    f"the fence port {fenced} is one the composer gives a real display"))
    if xml_fn(0, False) != LEGACY_DESKTOP_XML:
        bad.append(("DESKTOP-CHANGED",
                    "the desktop profile's input-port-associations.xml is no longer what every "
                    "desktop boot has staged"))
    for i in sorted({0, 1, max_id // 2, max_id}):
        table, dupes = associations(xml_fn(i, True))
        if dupes:
            bad.append(("DUPLICATE-INPUT", f"instance {i}'s XML names {dupes[0]} twice"))
        own = [n for n in ports if table.get(prefix_fn(i) + str(n)) != n]
        if own:
            bad.append(("OWN-UNBOUND",
                        f"instance {i}'s own phys for port {own[0]} is not bound to display port {own[0]}"))
        loose = [(j, n) for j in range(max_id + 1) if j != i for n in ports
                 if prefix_fn(j) + str(n) != prefix_fn(i) + str(n)
                 and table.get(prefix_fn(j) + str(n)) != fenced]
        shared = [n for n in ports if any(prefix_fn(j) == prefix_fn(i)
                                          for j in range(max_id + 1) if j != i)]
        if loose or shared:
            j, n = loose[0] if loose else (None, shared[0])
            who = f"instance {j}'s port {n}" if j is not None else f"another instance's port {n}"
            bad.append(("FOREIGN-UNFENCED",
                        f"instance {i}'s XML leaves {who} free to drive its own displays"))
    seen, out = set(), []
    for code, message in bad:
        if code not in seen:
            seen.add(code)
            out.append((code, message))
    return out


def code_only(text):
    """return the text without block and line comments"""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def function_body(text, signature):
    """return the body of the function with a signature, or None"""
    start = text.find(signature)
    if start < 0:
        return None
    open_at = text.find("{", start)
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def check_composer(text, prefix0):
    """check uinput.cpp builds phys with PortPhys"""
    code = code_only(text)
    body = function_body(code, "std::string PortPhys(")
    if body is None:
        return [("NO-PORTPHYS", "uinput.cpp has no PortPhys() building each device's phys")]
    bad = []
    if 'getenv("RHIZO_INPUT_PHYS_PREFIX")' not in body:
        bad.append(("NO-ENV", "PortPhys() does not read RHIZO_INPUT_PHYS_PREFIX"))
    fallback = re.search(r'\?\s*v\s*:\s*"([^"]*)"', body)
    if fallback is None or fallback.group(1) != prefix0:
        bad.append(("FALLBACK-DRIFT",
                    f"PortPhys()'s unset fallback is not instance 0's prefix {prefix0!r}"))
    outside = code.replace(body, "")
    if re.search(r'"[^"\n]*-port-"', outside):
        bad.append(("PHYS-LITERAL", "a device's phys is spelled out beside PortPhys()"))
    if len(re.findall(r"\bPortPhys\(\s*port\s*\)", outside)) < 2:
        bad.append(("PHYS-UNUSED",
                    "the pool's touchscreen and keyboard and its mouse do not all take PortPhys(port)"))
    return bad


def check_wiring(hals, rc, launcher):
    """return the input phys prefix wiring problems"""
    bad = []
    if not re.search(r"^# @RHIZO_SUBST input_phys_prefix$", rc, re.M):
        bad.append(("RC-NO-SUBST", "rhizo-composer.rc has no input_phys_prefix line"))
    if not re.search(r'"input_phys_prefix":\s*f"    setenv RHIZO_INPUT_PHYS_PREFIX '
                     r'\{input_phys_prefix\(SANDBOX_ID\)\}\\n"', hals):
        bad.append(("HALS-NO-SETENV",
                    "sandbox/hals.py does not hand the composer input_phys_prefix(SANDBOX_ID)"))
    if "input_port_associations_xml(SANDBOX_ID" not in launcher or 'input="rhizo-port-' in launcher:
        bad.append(("LAUNCHER-INLINE-XML",
                    "launcher3.py does not stage input_port_associations_xml(SANDBOX_ID, ...)"))
    elif not re.search(r'input_port_associations_xml\(SANDBOX_ID,\s*\w+\.scope\("rhizo\.profile"\)'
                       r'\s*==\s*"server"\)', launcher):
        bad.append(("LAUNCHER-FENCE-UNKEYED",
                    "launcher3.py does not fence exactly when this sandbox's profile is server"))
    return bad


def selftest():
    """check each planted-defect case against the findings it must produce"""
    ports = range(0, 9)

    def legacy_prefix(i):
        """return the old prefix that every port shares"""
        return "rhizo-port-"

    def legacy_xml(i, server):
        """return the old desktop port XML"""
        return LEGACY_DESKTOP_XML

    def good_prefix(i):
        """return the per-display input port prefix"""
        return "rhizo-port-" if i == 0 else f"rhizo-{i}-port-"

    def xml_with(prefix_fn, fence, max_id=5, desktop_extra=""):
        """return a function that builds port XML from a prefix function"""
        def build(i, server):
            """return the port XML for a display"""
            rows = [(prefix_fn(i) + str(n), n) for n in ports]
            if server:
                rows += [(prefix_fn(j) + str(n), fence)
                         for j in range(max_id + 1) if j != i for n in ports]
            body = "".join(f'    <port display="{d}" input="{p}" />\n' for p, d in rows)
            return ('<?xml version="1.0" encoding="utf-8"?>\n<ports>\n' + body
                    + desktop_extra * (not server) + "</ports>\n")
        return build

    def own_off(i, server):
        """return port XML where a display's port is moved"""
        text = xml_with(good_prefix, 255)(i, server)
        return text.replace(f'display="4" input="{good_prefix(i)}4"',
                            f'display="5" input="{good_prefix(i)}4"') if server else text

    good_uinput = '''
std::string PortPhys(int32_t port) {
  static const std::string prefix = [] {
    const char* v = getenv("RHIZO_INPUT_PHYS_PREFIX");
    return std::string(v && *v ? v : "rhizo-port-");
  }();
  return prefix + std::to_string(port);
}
bool SetupMouse(int fd, int32_t port) { return SetupCommon(fd, "m", PortPhys(port), 1); }
bool CreatePool(int32_t port) { const std::string phys = PortPhys(port); return true; }
'''
    good_rc = "# @RHIZO_SUBST input_phys_prefix\n"
    good_hals = ('"input_phys_prefix": f"    setenv RHIZO_INPUT_PHYS_PREFIX '
                 '{input_phys_prefix(SANDBOX_ID)}\\n" if SANDBOX_ID else "",')
    good_launcher = 'write(input_port_associations_xml(SANDBOX_ID, _p.scope("rhizo.profile") == "server"))'

    cases = (
        ("assoc: the fixed shape", lambda: check_associations(good_prefix, xml_with(good_prefix, 255), 5, ports, 255), set()),
        ("assoc: every instance rhizo-port-N, no fence", lambda: check_associations(legacy_prefix, legacy_xml, 5, ports, 255),
         {"PREFIX-COLLISION", "FOREIGN-UNFENCED"}),
        ("assoc: distinct prefixes, no fence", lambda: check_associations(good_prefix, legacy_xml, 5, ports, 255),
         {"OWN-UNBOUND", "FOREIGN-UNFENCED"}),
        ("assoc: fenced onto a real port", lambda: check_associations(good_prefix, xml_with(good_prefix, 3), 5, ports, 3),
         {"FENCE-IS-A-PORT"}),
        ("assoc: one foreign port left out", lambda: check_associations(good_prefix, xml_with(good_prefix, 255, max_id=4), 5, ports, 255),
         {"FOREIGN-UNFENCED"}),
        ("assoc: own port bound elsewhere", lambda: check_associations(good_prefix, own_off, 5, ports, 255),
         {"OWN-UNBOUND"}),
        ("assoc: desktop XML changed", lambda: check_associations(
            good_prefix, xml_with(good_prefix, 255, desktop_extra='    <port display="255" input="x" />\n'), 5, ports, 255),
         {"DESKTOP-CHANGED"}),
        ("composer: the fixed shape", lambda: check_composer(good_uinput, "rhizo-port-"), set()),
        ("composer: a literal phys in the pool", lambda: check_composer(
            good_uinput.replace("const std::string phys = PortPhys(port);",
                                'const std::string phys = "rhizo-port-" + std::to_string(port);'), "rhizo-port-"),
         {"PHYS-LITERAL", "PHYS-UNUSED"}),
        ("composer: no env read", lambda: check_composer(
            good_uinput.replace('getenv("RHIZO_INPUT_PHYS_PREFIX")', "nullptr"), "rhizo-port-"), {"NO-ENV"}),
        ("composer: fallback drifted", lambda: check_composer(good_uinput, "rhizo-0-port-"), {"FALLBACK-DRIFT"}),
        ("composer: no PortPhys", lambda: check_composer("int x;", "rhizo-port-"), {"NO-PORTPHYS"}),
        ("wiring: the fixed shape", lambda: check_wiring(good_hals, good_rc, good_launcher), set()),
        ("wiring: the fence never on", lambda: check_wiring(
            good_hals, good_rc, "write(input_port_associations_xml(SANDBOX_ID, False))"),
         {"LAUNCHER-FENCE-UNKEYED"}),
        ("wiring: nothing wired", lambda: check_wiring("", "", 'input="rhizo-port-{n}"'),
         {"RC-NO-SUBST", "HALS-NO-SETENV", "LAUNCHER-INLINE-XML"}),
    )
    failed = 0
    for name, run, want in cases:
        got = {code for code, _ in run()}
        if got != want:
            print(f"SELFTEST FAIL: {name}: wanted {sorted(want)}, got {sorted(got)}")
            failed += 1
    if failed:
        return 1
    print(f"check-input-port-fence selftest: {len(cases)} cases OK")
    return 0


def main(argv):
    """run the input-port-fence checks"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(USAGE)
        return 2
    sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
    with contextlib.redirect_stdout(io.StringIO()):
        from sandbox import core
    need = ("input_phys_prefix", "input_port_associations_xml", "INPUT_PORTS",
            "FENCED_DISPLAY_PORT", "MAX_SANDBOX_ID")
    missing = [n for n in need if not hasattr(core, n)]
    if missing:
        bad = [("NO-ENV-NAMES", f"src/androidd/sandbox/core.py lacks {', '.join(missing)}")]
        prefix0 = "rhizo-port-"
    else:
        bad = check_associations(core.input_phys_prefix, core.input_port_associations_xml,
                                 core.MAX_SANDBOX_ID, core.INPUT_PORTS,
                                 core.FENCED_DISPLAY_PORT)
        prefix0 = core.input_phys_prefix(0)
    texts = {}
    for path in (UINPUT, HALS, RC, LAUNCHER):
        with open(path) as f:
            texts[path] = f.read()
    bad += check_composer(texts[UINPUT], prefix0)
    bad += check_wiring(texts[HALS], texts[RC], texts[LAUNCHER])
    for code, message in bad:
        print(f"FAIL {code}: {message}")
    if bad:
        return 1
    print("OK: every instance's input devices carry their own phys, and server instances fence each other's")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
