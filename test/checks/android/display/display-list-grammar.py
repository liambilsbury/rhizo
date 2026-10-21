#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
COMPOSER = os.path.join(ROOT, "src", "android", "hal", "graphics-composer", "src", "composer.cpp")
LIB = os.path.join(ROOT, "src", "androidd", "host", "parse-display-list.sh")

CONSUMERS = [
    "src/androidd/host/fill-display-pool.sh",
    "src/androidd/host/release-idle-display.sh",
    "test/system/desktop/launcher.sh",
    "test/system/desktop/display.sh",
    "test/system/desktop/display-stress.sh",
]

INLINE_RE = re.compile(r"pool\\?\)|pool\)\?|,pool\)")

DISPLAYS = [
    {"id": 1, "w": 1280, "h": 800, "claimed": True, "p": 400, "v": 1},
    {"id": 7, "w": 960, "h": 1080, "claimed": True, "p": 12, "v": 1},
    {"id": 8, "w": 960, "h": 1080, "claimed": False, "p": 3, "v": 0},
]


def builder_expression(source):
    """return the display token builder expression"""
    m = re.search(r"\bids\s*\+=\s*(.*?);", source, re.S)
    if not m:
        raise ValueError("no `ids += ...;` builder found in the composer source")
    return m.group(1)


TOKEN_RE = re.compile(
    r'"((?:[^"\\]|\\.)*)"'
    r"|std::to_string\(((?:[^()]|\([^()]*\))*)\)"
    r"|\(\s*([^?()]*?)\s*\?\s*\"([^\"]*)\"\s*:\s*\"([^\"]*)\"\s*\)"
    r"|(\S)"
)

FIELD_FOR = (("first", "id"), ("width", "w"), ("height", "h"),
             ("presentCount", "p"), ("vsyncEnabled", "v"))


def render_token(expr, d):
    """render a display token from the builder"""
    out = []
    for m in TOKEN_RE.finditer(expr):
        if m.group(1) is not None:
            out.append(m.group(1))
        elif m.group(2) is not None:
            inner = m.group(2)
            for needle, key in FIELD_FOR:
                if needle in inner:
                    value = d[key]
                    if key == "v" and "?" in inner:
                        value = 1 if d["v"] else 0
                    out.append(str(value))
                    break
            else:
                out.append("0")
        elif m.group(3) is not None:
            cond = m.group(3)
            if "claimed" not in cond:
                raise ValueError("ternary on %r is not the claimed flag" % cond)
            out.append(m.group(4) if d["claimed"] else m.group(5))
        else:
            ch = m.group(6)
            if ch not in "+":
                raise ValueError("cannot render builder piece %r" % ch)
    return "".join(out)


def render_reply(source, displays=DISPLAYS):
    """render the composer's display list reply"""
    expr = builder_expression(source)
    if "?" in expr and not re.search(r"\?\s*\"[^\"]*\"\s*:\s*\"[^\"]*\"", expr):
        raise ValueError("the claimed ternary has a non-literal arm")
    return "display list " + "".join(render_token(expr, d) for d in displays)


def run_lib(shell, lib, reply):
    """run the display list functions under a shell"""
    script = """. "$1"
r="$2"
printf 'ids=%s\\n' "$(rhizo_dl_ids "$r" | tr '\\n' ' ')"
printf 'spares=%s\\n' "$(rhizo_dl_spares "$r" | tr '\\n' ' ')"
printf 'claimed=%s\\n' "$(rhizo_dl_claimed "$r" | tr '\\n' ' ')"
printf 'geom8=%s\\n' "$(rhizo_dl_geometry "$r" 8)"
printf 'geoms=%s\\n' "$(rhizo_dl_geometries "$r" | tr '\\n' ' ')"
printf 'p8=%s\\n' "$(rhizo_dl_field "$r" 8 p)"
printf 'v1=%s\\n' "$(rhizo_dl_field "$r" 1 v)"
"""
    p = subprocess.run([shell, "-c", script, "lib", lib, reply],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise ValueError("%s failed under %s: %s" % (lib, shell, p.stderr.strip()))
    return dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)


def check_parse(lib, reply, has_fields):
    """return the reply parse failures"""
    failures = []
    for shell in ("sh", "bash"):
        got = run_lib(shell, lib, reply)
        want = {
            "ids": "1 7 8 ",
            "spares": "8 ",
            "claimed": "1 7 ",
            "geom8": "960x1080",
            "geoms": "1280x800 960x1080 960x1080 ",
        }
        if has_fields:
            want["p8"] = "3"
            want["v1"] = "1"
        for key, value in want.items():
            if got.get(key) != value:
                failures.append("PARSE-%s: under %s %s answered %r, expected %r for %r"
                                % (key.upper(), shell, os.path.basename(lib), got.get(key),
                                   value, reply))
    return failures


def check_consumers(root, consumers):
    """check that consumer scripts parse the display list reply"""
    failures = []
    for rel in consumers:
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            failures.append("MISSING-CONSUMER: %s is listed but does not exist" % rel)
            continue
        with open(path) as f:
            for n, line in enumerate(f, 1):
                if line.lstrip().startswith("#"):
                    continue
                if INLINE_RE.search(line):
                    failures.append("INLINE-PATTERN: %s:%d binds the pool flag to the closing "
                                    "paren; parse through rhizo-display-list.sh instead" % (rel, n))
    return failures


def run_check(composer, lib, root, consumers):
    """check the composer's reply and its consumers"""
    with open(composer) as f:
        source = f.read()
    try:
        reply = render_reply(source)
    except ValueError as e:
        return ["RENDER-REFUSED: %s" % e]
    has_fields = ",p=" in reply
    failures = check_parse(lib, reply, has_fields)
    failures += check_consumers(root, consumers)
    return failures


OLD_BUILDER = '''
          ids += std::to_string(kv.first) + "(" + std::to_string(kv.second.width) + "x" +
                 std::to_string(kv.second.height) +
                 (kv.second.claimed ? "" : ",pool") + ") ";
'''

NEW_BUILDER = '''
          ids += std::to_string(kv.first) + "(" + std::to_string(kv.second.width) + "x" +
                 std::to_string(kv.second.height) +
                 (kv.second.claimed ? "" : ",pool") +
                 ",p=" + std::to_string(kv.second.presentCount) +
                 ",v=" + std::to_string(kv.second.vsyncEnabled ? 1 : 0) + ") ";
'''

FUTURE_BUILDER = NEW_BUILDER.replace('+ ") ";', '+ ",q=" + std::to_string(kv.second.queued) + ") ";')

UNRENDERABLE_BUILDER = NEW_BUILDER.replace('(kv.second.claimed ? "" : ",pool")',
                                           '(kv.second.claimed ? "" : SpareTag())')

OLD_LIB = r'''
rhizo_dl_tokens() { printf '%s\n' "$1" | grep -oE '[0-9]+\([0-9]+x[0-9]+(,pool)?\)'; }
rhizo_dl_ids() { rhizo_dl_tokens "$1" | grep -oE '^[0-9]+'; }
rhizo_dl_spares() { rhizo_dl_tokens "$1" | grep ',pool)' | grep -oE '^[0-9]+'; }
rhizo_dl_claimed() { rhizo_dl_tokens "$1" | grep -v ',pool)' | grep -oE '^[0-9]+'; }
rhizo_dl_geometry() { rhizo_dl_tokens "$1" | grep -E "^$2\(" | sed -E 's/^[0-9]+\(([0-9]+x[0-9]+).*/\1/'; }
rhizo_dl_geometries() { rhizo_dl_tokens "$1" | sed -E 's/^[0-9]+\(([0-9]+x[0-9]+).*/\1/'; }
rhizo_dl_field() { :; }
'''


def selftest():
    """return the selftest case failures"""
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        def write(name, text):
            """write a file under the temporary directory and return its path"""
            path = os.path.join(tmp, name)
            with open(path, "w") as f:
                f.write(text)
            return path

        def expect(label, got, want_codes):
            """record a failure unless the codes match"""
            codes = sorted({f.split(":", 1)[0] for f in got})
            if codes != sorted(want_codes):
                failures.append("%s: got %s, expected %s -- %s" % (label, codes, sorted(want_codes), got))

        old = write("old.cpp", OLD_BUILDER)
        new = write("new.cpp", NEW_BUILDER)
        future = write("future.cpp", FUTURE_BUILDER)
        bad = write("bad.cpp", UNRENDERABLE_BUILDER)
        oldlib = write("oldlib.sh", OLD_LIB)
        write("clean.sh", '. lib\nspares=$(rhizo_dl_spares "$dl")\n')
        write("inline.sh", "spare=$(grep -oE '[0-9]+\\([0-9]+x[0-9]+,pool\\)' <<<\"$dl\")\n")
        write("inline2.sh", "n=$(printf '%s\\n' \"$dl\" | grep -c ',pool)' || true)\n")
        write("comment.sh", "# a comment may say ,pool) in prose\n")

        expect("real lib, current builder", run_check(new, LIB, tmp, ["clean.sh"]), [])
        expect("real lib, old builder", run_check(old, LIB, tmp, ["clean.sh"]), [])
        expect("real lib, future field", run_check(future, LIB, tmp, ["clean.sh"]), [])
        got = run_check(new, oldlib, tmp, ["clean.sh"])
        if not any(f.startswith("PARSE-SPARES") for f in got) or \
           not any(f.startswith("PARSE-CLAIMED") for f in got):
            failures.append("old lib must fail spares and claimed on the current grammar: %s" % got)
        got = run_check(old, oldlib, tmp, ["clean.sh"])
        if any(f.startswith("PARSE-SPARES") or f.startswith("PARSE-CLAIMED") for f in got):
            failures.append("old lib on the old builder must parse spares and claimed: %s" % got)
        expect("unrenderable builder", run_check(bad, LIB, tmp, ["clean.sh"]), ["RENDER-REFUSED"])
        expect("inline pattern", run_check(new, LIB, tmp, ["inline.sh"]), ["INLINE-PATTERN"])
        expect("inline grep -c", run_check(new, LIB, tmp, ["inline2.sh"]), ["INLINE-PATTERN"])
        expect("prose in a comment", run_check(new, LIB, tmp, ["comment.sh"]), [])
        expect("missing consumer", run_check(new, LIB, tmp, ["absent.sh"]), ["MISSING-CONSUMER"])
    return failures


def main():
    """run the check or its selftest and print the failures"""
    if "--selftest" in sys.argv[1:]:
        failures = selftest()
        label = "check-display-list-grammar selftest"
    else:
        failures = run_check(COMPOSER, LIB, ROOT, CONSUMERS)
        label = "check-display-list-grammar"
    for f in failures:
        print("%s: %s" % (label, f))
    if failures:
        print("%s: FAIL (%d)" % (label, len(failures)))
        return 1
    print("%s: ok" % label)
    return 0


if __name__ == "__main__":
    sys.exit(main())
