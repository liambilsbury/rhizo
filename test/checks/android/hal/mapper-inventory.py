#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_PATH = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "gralloc-mapper", "src", "mapper.cpp")


def strip_comments(text):
    """remove comments from C++ source"""
    out = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            i = text.find("\n", i)
            if i == -1:
                i = n
            continue
        if two == "/*":
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
            continue
        c = text[i]
        if c in ('"', "'"):
            out.append(c)
            i += 1
            while i < n:
                out.append(text[i])
                if text[i] == "\\" and i + 1 < n:
                    out.append(text[i + 1])
                    i += 2
                    continue
                done = text[i] == c
                i += 1
                if done:
                    break
            continue
        out.append(c)
        i += 1
    return "".join(out)


def brace_body(text, needle):
    """return the {...} block at needle"""
    idx = text.find(needle)
    if idx == -1:
        return None
    brace = text.find("{", idx)
    if brace == -1:
        return None
    depth = 0
    i = brace
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace:i + 1]
        i += 1
    return None


def check(text):
    """check the mapper's buffer inventory locking"""
    text = strip_comments(text)
    failures = []

    struct_body = brace_body(text, "struct ImportedBuffer")
    if struct_body is None:
        failures.append(("NO-STRUCT", "struct ImportedBuffer not found"))
    elif not re.search(r"\bino_t\s+ino\b", struct_body):
        failures.append(("NO-INO-FIELD", "ImportedBuffer has no ino_t ino member"))

    import_body = brace_body(text, "importBuffer(")
    if import_body is None:
        failures.append(("NO-IMPORT", "importBuffer( not found"))
    else:
        fstat_m = re.search(r"\bfstat\(", import_body)
        assign_m = re.search(r"\bib\.ino\s*=", import_body)
        if not fstat_m:
            failures.append(("NO-FSTAT-AT-IMPORT", "importBuffer() calls no fstat()"))
        if not assign_m:
            failures.append(("NO-INO-ASSIGN", "importBuffer() never assigns ib.ino"))
        if fstat_m and assign_m and not (fstat_m.start() < assign_m.start()):
            failures.append(("INO-ASSIGNED-BEFORE-FSTAT", "ib.ino is assigned before "
                             "fstat() runs"))

    dump_body = brace_body(text, "dumpAllBuffers(")
    if dump_body is None:
        failures.append(("NO-DUMPALLBUFFERS", "dumpAllBuffers( not found"))
    else:
        for_m = re.search(r"\bfor\s*\(", dump_body)
        imported_m = re.search(r"\bg_imported\b", dump_body)
        mutex_m = re.search(r"\bg_mutex\b", dump_body)
        if not for_m or not imported_m:
            failures.append(("STUB-STILL-PRESENT", "dumpAllBuffers() has no loop over "
                             "g_imported"))
        if not mutex_m:
            failures.append(("NO-MUTEX-GUARD", "dumpAllBuffers() never mentions g_mutex"))
        if for_m and mutex_m and not (mutex_m.start() < for_m.start()):
            failures.append(("MUTEX-AFTER-LOOP", "g_mutex is referenced after the loop "
                             "starts, not before it"))

    return failures


GOOD_SRC = """
struct ImportedBuffer {
  DecodedHandle decoded;
  ino_t ino = 0;
};
std::mutex g_mutex;
std::unordered_map<buffer_handle_t, ImportedBuffer> g_imported;
AIMapper_Error importBuffer(const native_handle_t* handle, buffer_handle_t* outBufferHandle) {
  int dupFd = dup(handle->data[0]);
  struct stat st{};
  ino_t ino = (fstat(dupFd, &st) == 0) ? st.st_ino : 0;
  std::lock_guard<std::mutex> lock(g_mutex);
  ImportedBuffer& ib = g_imported[cloned];
  ib.decoded = decoded;
  ib.ino = ino;
  return AIMAPPER_ERROR_NONE;
}
AIMapper_Error dumpAllBuffers(Begin beginCb, Dump dumpCb, void* context) {
  std::lock_guard<std::mutex> lg(g_mutex);
  for (const auto& entry : g_imported) {
    beginCb(context);
    dumpCb(context, {"rhizo.ino", 1}, &entry.second.ino, sizeof(entry.second.ino));
  }
  return AIMAPPER_ERROR_NONE;
}
"""

BAD_STUB = GOOD_SRC.replace(
    "std::lock_guard<std::mutex> lg(g_mutex);\n"
    "  for (const auto& entry : g_imported) {\n"
    "    beginCb(context);\n"
    '    dumpCb(context, {"rhizo.ino", 1}, &entry.second.ino, sizeof(entry.second.ino));\n'
    "  }\n", "")
BAD_NO_MUTEX = GOOD_SRC.replace(
    "  std::lock_guard<std::mutex> lg(g_mutex);\n  for (const auto& entry : g_imported) {",
    "  for (const auto& entry : g_imported) {")
BAD_MUTEX_AFTER_LOOP = GOOD_SRC.replace(
    "  std::lock_guard<std::mutex> lg(g_mutex);\n  for (const auto& entry : g_imported) {\n"
    "    beginCb(context);",
    "  for (const auto& entry : g_imported) {\n"
    "    std::lock_guard<std::mutex> lg(g_mutex);\n    beginCb(context);")
BAD_NO_INO_FIELD = GOOD_SRC.replace("  ino_t ino = 0;\n", "")
BAD_NO_FSTAT_AT_IMPORT = GOOD_SRC.replace(
    "  struct stat st{};\n  ino_t ino = (fstat(dupFd, &st) == 0) ? st.st_ino : 0;\n",
    "  ino_t ino = 0;\n")
BAD_NO_INO_ASSIGN = GOOD_SRC.replace("  ib.ino = ino;\n", "")


def selftest():
    """check each source shape against whether it must pass"""
    cases = [
        ("fully wired", GOOD_SRC, True),
        ("dumpAllBuffers still the stub", BAD_STUB, False),
        ("loop over g_imported with no lock", BAD_NO_MUTEX, False),
        ("lock taken after the loop already started", BAD_MUTEX_AFTER_LOOP, False),
        ("ImportedBuffer has no ino field", BAD_NO_INO_FIELD, False),
        ("importBuffer never fstats the imported fd", BAD_NO_FSTAT_AT_IMPORT, False),
        ("fstat's result never reaches ib.ino", BAD_NO_INO_ASSIGN, False),
    ]
    failed = False
    for name, src, want_clean in cases:
        got_clean = not check(src)
        if got_clean != want_clean:
            print(f"SELFTEST FAIL: {name} -- expected clean={want_clean}, got clean={got_clean}")
            failed = True
    if failed:
        return 1
    print("selftest ok: every fixture behaves as expected")
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv:
        return selftest()
    with open(SRC_PATH) as f:
        text = f.read()
    failures = check(text)
    if failures:
        for code, msg in failures:
            print(f"{code}: {msg}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
