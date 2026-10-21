#!/usr/bin/env python3
"""Parse SELinux AVC denial records from a dmesg capture"""
import re
import sys
from collections import OrderedDict

USAGE = """Usage:
  parse-avc.py <capture.log>                  summarize one capture
  parse-avc.py --diff <a.log> <b.log>         denials new in b / gone from a
  parse-avc.py --cil <capture.log>            one CIL allow rule per denial group
  parse-avc.py --cil --domain rhizo_host ...  limit rules to that source domain
  parse-avc.py --selftest                     run the built-in tests"""

AVC_RE = re.compile(r'avc:\s*denied\s*\{\s*(?P<perms>[^}]*)\}\s*for\s+(?P<rest>.*)')
KV_RE = re.compile(r'(\w+)=("(?:[^"\\]|\\.)*"|\S+)')


def parse_line(line):
    """parse a dmesg line into an AVC record"""
    m = AVC_RE.search(line)
    if not m:
        return None
    perms = tuple(sorted(m.group('perms').split()))
    kv = {}
    for km in KV_RE.finditer(m.group('rest')):
        k, v = km.group(1), km.group(2)
        if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
            v = v[1:-1]
        kv[k] = v
    return {
        'perms': perms,
        'scontext': kv.get('scontext', '?'),
        'tcontext': kv.get('tcontext', '?'),
        'tclass': kv.get('tclass', '?'),
        'permissive': kv.get('permissive', '?'),
        'comm': kv.get('comm', '?'),
        'pid': kv.get('pid', '?'),
        'path': kv.get('path', kv.get('name', '')),
        'line': line.rstrip('\n'),
    }


def load(path):
    """return the parsed denial records of a file"""
    records = []
    with open(path, 'r', errors='replace') as f:
        for line in f:
            r = parse_line(line)
            if r:
                records.append(r)
    return records


def dedupe(records):
    """group the denial records into counted groups"""
    groups = OrderedDict()
    for r in records:
        key = (r['scontext'], r['tcontext'], r['tclass'], r['perms'])
        g = groups.setdefault(key, {'count': 0, 'example': r, 'permissive': set()})
        g['count'] += 1
        g['permissive'].add(r['permissive'])
    return groups


def short_type(ctx):
    """return the type field of a context"""
    parts = ctx.split(':')
    return parts[2] if len(parts) >= 3 else ctx


def suggest_cil(key):
    """return the CIL allow rule for a rule key"""
    scontext, tcontext, tclass, perms = key
    return f'(allow {short_type(scontext)} {short_type(tcontext)} ({tclass} ({" ".join(perms)})))'


def print_summary(groups, records):
    """print the denial groups and counts"""
    perm0 = sum(1 for r in records if r['permissive'] == '0')
    perm1 = sum(1 for r in records if r['permissive'] == '1')
    print(f'total_denial_lines={len(records)} permissive=0:{perm0} permissive=1:{perm1}')
    if records and perm1 and not perm0:
        print('WARNING: every denial has permissive=1 -- SELinux was not enforcing for any domain that hit a denial in this capture')
    elif perm0 and perm1:
        print('NOTE: capture has a mix of permissive=0 and permissive=1 denials')
    print(f'unique_denials={len(groups)}')
    for key, g in groups.items():
        scontext, tcontext, tclass, perms = key
        print(f'--- count={g["count"]} scontext={scontext} tcontext={tcontext} '
              f'tclass={tclass} perms={{{",".join(perms)}}} '
              f'permissive={{{",".join(sorted(g["permissive"]))}}} '
              f'comm={g["example"]["comm"]} pid={g["example"]["pid"]}')
        print(f'    example: {g["example"]["line"]}')
        print(f'    suggested CIL: {suggest_cil(key)}')


def print_diff(groups_a, groups_b):
    """print the rules new in the second capture and gone from the first"""
    keys_a, keys_b = set(groups_a), set(groups_b)
    only_b = keys_b - keys_a
    only_a = keys_a - keys_b
    print(f'new_in_b={len(only_b)} gone_from_a={len(only_a)} unchanged={len(keys_a & keys_b)}')
    for key in only_b:
        print(f'+ count={groups_b[key]["count"]} {suggest_cil(key)}')
    for key in only_a:
        print(f'- count={groups_a[key]["count"]} {suggest_cil(key)}')


def by_rule(records):
    """merge the denial records into CIL rules"""
    rules = {}
    for r in records:
        key = (short_type(r['scontext']), short_type(r['tcontext']), r['tclass'])
        e = rules.setdefault(key, {'count': 0, 'perms': set(), 'comm': r['comm'],
                                   'path': r['path'], 'permissive': set()})
        e['count'] += 1
        e['perms'].update(r['perms'])
        e['permissive'].add(r['permissive'])
        if not e['path'] and r['path']:
            e['path'] = r['path']
    return rules


def print_cil(records, domain):
    """print the CIL rules for the denials"""
    if domain:
        records = [r for r in records if short_type(r['scontext']) == domain]
    rules = by_rule(records)
    print(f'; {len(rules)} rule(s) from {len(records)} denial line(s)'
          + (f', source domain {domain}' if domain else ''))
    print('; REVIEW EACH: a rule here is what the kernel asked for, not what policy should say')
    for key in sorted(rules):
        sdomain, ttype, tclass = key
        e = rules[key]
        where = f' path={e["path"]}' if e['path'] else ''
        print(f'; count={e["count"]} comm={e["comm"]}{where} '
              f'permissive={{{",".join(sorted(e["permissive"]))}}}')
        print(f'(allow {sdomain} {ttype} ({tclass} ({" ".join(sorted(e["perms"]))})))')


SELFTEST_CAPTURE = """[   12.345678] audit: type=1400 audit(1699999999.123:45): avc:  denied  { mounton } for  pid=5288 comm="python3" path="/" dev="vda1" ino=2 scontext=u:r:rhizo_host:s0 tcontext=u:object_r:rootfs:s0 tclass=dir permissive=0
[   12.345999] audit: type=1400 audit(1699999999.124:46): avc:  denied  { search } for  pid=5288 comm="python3" name="vendor" dev="vda1" ino=529625 scontext=u:r:rhizo_host:s0 tcontext=u:object_r:rootfs:s0 tclass=dir permissive=0
[   13.000000] audit: type=1400 audit(1699999999.500:47): avc:  denied  { search } for  pid=5817 comm="vendor_init" name="vendor" dev="vda1" ino=529625 scontext=u:r:vendor_init:s0 tcontext=u:object_r:unlabeled:s0 tclass=dir permissive=0
[   13.100000] audit: type=1400 audit(1699999999.600:48): avc:  denied  { ioctl } for  pid=5451 comm="python3" path="/proc/1798/cmdline" dev="proc" ino=14564 ioctlcmd=0x5401 scontext=u:r:rhizo_host:s0 tcontext=u:r:vendor_init:s0 tclass=file permissive=1
a line that is not a denial at all
"""


def selftest():
    """test the parser on sample capture lines"""
    import tempfile, os as _os
    ran = 0

    def check(cond, what):
        """count a passed check and raise unless the condition holds"""
        nonlocal ran
        if not cond:
            raise AssertionError(what)
        ran += 1

    fd, path = tempfile.mkstemp(prefix='parse-avc-selftest.')
    try:
        with _os.fdopen(fd, 'w') as f:
            f.write(SELFTEST_CAPTURE)
        records = load(path)
    finally:
        _os.unlink(path)

    check(len(records) == 4, f'expected 4 denial records, got {len(records)}')
    check(records[0]['path'] == '/', f'path= not captured: {records[0]["path"]!r}')
    check(records[1]['path'] == 'vendor', f'name= not captured: {records[1]["path"]!r}')
    check(records[3]['perms'] == ('ioctl',),
          f'ioctlcmd= shifted the perm scan: {records[3]["perms"]!r}')
    check(records[3]['tcontext'] == 'u:r:vendor_init:s0',
          f'ioctlcmd= shifted the field scan: {records[3]["tcontext"]!r}')

    check(len(dedupe(records)) == 4, 'four distinct perm tuples must stay four summary groups')

    rules = by_rule(records)
    key = ('rhizo_host', 'rootfs', 'dir')
    check(key in rules, f'{key} missing from the rule set: {sorted(rules)}')
    check(rules[key]['perms'] == {'mounton', 'search'},
          f'perms did not union across two lines: {rules[key]["perms"]}')
    check(rules[key]['count'] == 2, f'count did not sum: {rules[key]["count"]}')
    check(rules[key]['path'] == '/', f'first example path lost: {rules[key]["path"]!r}')
    check(('vendor_init', 'unlabeled', 'dir') in rules, 'second source domain dropped')

    filtered = by_rule([r for r in records if short_type(r['scontext']) == 'rhizo_host'])
    check(('vendor_init', 'unlabeled', 'dir') not in filtered,
          '--domain filter kept a rule from another source domain')
    check(len(filtered) == 2, f'--domain rhizo_host should leave 2 rules, got {len(filtered)}')

    import io as _io
    import contextlib as _contextlib
    buf = _io.StringIO()
    with _contextlib.redirect_stdout(buf):
        print_cil(records, 'rhizo_host')
    out = buf.getvalue()
    check('(allow rhizo_host rootfs (dir (mounton search)))' in out,
          f'rule text wrong or unsorted:\n{out}')
    check('vendor_init unlabeled' not in out, f'--domain filter leaked into the text:\n{out}')
    check(out.index('; count=2') < out.index('(allow rhizo_host rootfs'),
          f'count comment must sit above its rule:\n{out}')

    check(parse_line('a line that is not a denial at all') is None,
          'a non-denial line parsed as a denial')

    print(f'parse-avc selftest: {ran} assertions passed')


def main():
    """run the selftest or the requested summary"""
    args = sys.argv[1:]
    if not args:
        print(__doc__ + "\n\n" + USAGE)
        sys.exit(2)
    if args[0] == '--selftest':
        selftest()
        return
    if args[0] == '--diff':
        if len(args) != 3:
            print('usage: parse-avc.py --diff <a.log> <b.log>', file=sys.stderr)
            sys.exit(2)
        print_diff(dedupe(load(args[1])), dedupe(load(args[2])))
        return
    cil = False
    domain = None
    rest = []
    i = 0
    while i < len(args):
        if args[i] == '--cil':
            cil = True
        elif args[i] == '--domain':
            if i + 1 >= len(args):
                print('usage: parse-avc.py --cil --domain <type> <capture.log>', file=sys.stderr)
                sys.exit(2)
            domain = args[i + 1]
            i += 1
        elif args[i].startswith('--'):
            print(f'unknown option {args[i]}', file=sys.stderr)
            sys.exit(2)
        else:
            rest.append(args[i])
        i += 1
    if len(rest) != 1:
        print('usage: parse-avc.py [--cil] [--domain <type>] <capture.log>', file=sys.stderr)
        sys.exit(2)
    if domain and not cil:
        print('--domain only filters --cil output', file=sys.stderr)
        sys.exit(2)
    records = load(rest[0])
    if cil:
        print_cil(records, domain)
        return
    print_summary(dedupe(records), records)


if __name__ == '__main__':
    main()
