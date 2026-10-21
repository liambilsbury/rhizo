#!/usr/bin/env python3
"""Plan which .debs of a staged package pool to install on a host"""
import argparse
import glob
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

ALT_RE = re.compile(r'^([a-z0-9][a-z0-9+.-]*)(?::[a-z0-9-]+)?\s*'
                    r'(?:\(\s*(<<|<=|=|>=|>>|<|>)\s*([^)\s]+)\s*\))?')
OPS = {'<<': 'lt', '<=': 'le', '=': 'eq', '>=': 'ge', '>>': 'gt', '<': 'le', '>': 'ge'}
_cmp_cache = {}


def version_ok(have, op, want):
    """compare versions with dpkg --compare-versions"""
    if op is None:
        return True
    key = (have, op, want)
    if key not in _cmp_cache:
        rc = subprocess.run(['dpkg', '--compare-versions', have, OPS[op], want],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        _cmp_cache[key] = rc == 0
    return _cmp_cache[key]


def parse_rel(field):
    """parse a Depends field into clauses"""
    clauses = []
    for part in (field or '').split(','):
        part = part.strip()
        if not part:
            continue
        alts = []
        for alt in part.split('|'):
            m = ALT_RE.match(alt.strip())
            if m:
                alts.append((m.group(1), m.group(2), m.group(3)))
        if alts:
            clauses.append(alts)
    return clauses


def parse_provides(field):
    """return each provided name with its exact version"""
    return [(a[0][0], a[0][2] if a[0][1] == '=' else None) for a in parse_rel(field)]


def fmt_clause(clause):
    """format a dependency clause as a text of alternatives"""
    return ' | '.join(f'{n} ({o} {v})' if o else n for n, o, v in clause)


class Pkg:
    def __init__(self, name, version, depends, provides, path=None, status=''):
        """store the package fields"""
        self.name = name
        self.version = version
        self.deps = parse_rel(depends)
        self.provides = parse_provides(provides)
        self.path = path
        self.status = status


def configured(p):
    """return true for a configured package"""
    return p.status[1:2] == 'i' and not p.status[2:].strip()


def read_installed(admindir):
    """read installed packages from dpkg-query"""
    cmd = ['dpkg-query']
    if admindir:
        cmd.append(f'--admindir={admindir}')
    cmd += ['-W', '-f=${Package}\\t${Version}\\t${db:Status-Abbrev}\\t${Provides}\\t'
            '${Depends}\\t${Pre-Depends}\\n']
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise OSError(f'dpkg-query failed ({r.returncode}): {r.stderr.strip()}')
    installed = {}
    for line in r.stdout.splitlines():
        f = line.split('\t')
        if len(f) < 6:
            continue
        name, ver, abbrev, prov, dep, pre = f[:6]
        if len(abbrev) < 2 or abbrev[1] in 'nc':
            continue
        installed[name] = Pkg(name, ver, ', '.join(x for x in (pre, dep) if x), prov,
                              status=abbrev.strip())
    return installed


def read_pool(pool_dir):
    """read every .deb in a folder"""
    pool, dupes = {}, []
    files = sorted(glob.glob(os.path.join(pool_dir, '*.deb')))
    if not files:
        raise OSError(f'no .deb files in {pool_dir}')
    for path in files:
        r = subprocess.run(['dpkg-deb', '-f', path, 'Package', 'Version', 'Depends',
                            'Pre-Depends', 'Provides'], capture_output=True, text=True)
        if r.returncode != 0:
            raise OSError(f'dpkg-deb could not read {path}: {r.stderr.strip()}')
        fields = {}
        for line in r.stdout.splitlines():
            k, _, v = line.partition(':')
            fields[k.strip()] = v.strip()
        name, ver = fields.get('Package'), fields.get('Version')
        if not name or not ver:
            raise OSError(f'{path} has no Package/Version')
        p = Pkg(name, ver, ', '.join(x for x in (fields.get('Pre-Depends'), fields.get('Depends')) if x),
                fields.get('Provides'), path=path)
        if name in pool:
            older, newer = (pool[name], p) if version_ok(p.version, '>>', pool[name].version) else (p, pool[name])
            dupes.append(older)
            pool[name] = newer
        else:
            pool[name] = p
    return pool, dupes


def plan(pool, installed, roots, allow):
    """return the plan lines and unmet needs"""
    chosen = {}
    need = []

    def current(name):
        """return the package chosen for a name, else the installed one"""
        if name in chosen:
            return pool[name]
        return installed.get(name)

    def providers():
        """map each provided name to the packages that provide it"""
        out = {}
        for name in set(installed) | set(chosen):
            p = current(name)
            for vname, vver in p.provides:
                out.setdefault(vname, []).append((p, vver))
        return out

    def usable(p):
        """return true for pool and configured packages"""
        return p.path is not None or configured(p)

    def sat(alt, state_current, prov):
        """return whether an alternative is met"""
        name, op, ver = alt
        p = state_current(name)
        if p is not None and usable(p) and version_ok(p.version, op, ver):
            return True
        for pp, pv in prov.get(name, []):
            if usable(pp) and (op is None or (pv is not None and version_ok(pv, op, ver))):
                return True
        return False

    def state(name):
        """return a note on a package's dpkg state"""
        p = installed[name]
        return '' if configured(p) else f' (dpkg state {p.status!r}, not configured)'

    queue = []

    def choose(name, how):
        """mark a package as chosen"""
        chosen[name] = how
        queue.append(name)

    for root in roots:
        if root in installed:
            if not configured(installed[root]):
                need.append((root, f'is a root this host has at {installed[root].version} in dpkg state '
                                   f'{installed[root].status!r}, not configured (ii) -- configure or '
                                   'reinstall it'))
            continue
        if root in pool:
            choose(root, 'INSTALL')
        else:
            need.append((root, 'is a root, not installed on this host and not in the pool'))

    def resolve(owner, clause):
        """pick a pool package for an unmet clause or record a need"""
        prov = providers()
        if any(sat(a, current, prov) for a in clause):
            return
        for name, op, ver in clause:
            if name in pool and name not in installed and version_ok(pool[name].version, op, ver):
                choose(name, 'INSTALL')
                return
        for name, op, ver in clause:
            for cand in sorted(pool):
                if cand in installed or cand in chosen:
                    continue
                for vname, vver in pool[cand].provides:
                    if vname == name and (op is None or (vver and version_ok(vver, op, ver))):
                        choose(cand, 'INSTALL')
                        return
        for name, op, ver in clause:
            if name in installed and name in allow and name in pool \
                    and version_ok(pool[name].version, op, ver):
                choose(name, 'UPGRADE')
                return
        have = [f'{n} {installed[n].version}{state(n)}' for n, _, _ in clause if n in installed]
        offer = [f'{n} {pool[n].version}' for n, _, _ in clause if n in pool]
        why = f'Depends {fmt_clause(clause)}, but this host has {", ".join(have) or "none of it"}'
        why += f' and the pool carries {", ".join(offer) or "none of it"}'
        if have and not any(n in allow for n, _, _ in clause):
            why += ' (upgrading an installed package needs --allow-upgrade)'
        need.append((owner, why))

    while True:
        while queue:
            name = queue.pop(0)
            for clause in pool[name].deps:
                resolve(name, clause)
        upgraded = {n for n, how in chosen.items() if how == 'UPGRADE'}
        if not upgraded:
            break
        touched = set(upgraded)
        for n in upgraded:
            touched.update(v for v, _ in installed[n].provides)
        prov_before, prov_after = {}, providers()
        for p in installed.values():
            for vname, vver in p.provides:
                prov_before.setdefault(vname, []).append((p, vver))
        grew = False
        for q in sorted(installed):
            if q in chosen:
                continue
            for clause in installed[q].deps:
                if not any(a[0] in touched for a in clause):
                    continue
                before = any(sat(a, installed.get, prov_before) for a in clause)
                after = any(sat(a, current, prov_after) for a in clause)
                if before and not after:
                    if q in allow and q in pool:
                        choose(q, 'UPGRADE')
                        grew = True
                    else:
                        by = ', '.join(sorted(upgraded))
                        entry = (q, f'installed {q} {installed[q].version} Depends '
                                    f'{fmt_clause(clause)}, which upgrading {by} breaks')
                        if entry not in need:
                            need.append(entry)
                    break
        if not grew:
            break

    owners = {o for o, _ in need}
    for name in sorted(pool):
        if name not in chosen and name in installed and not configured(installed[name]) \
                and name not in owners:
            need.append((name, f'this host has {installed[name].version} in dpkg state '
                               f'{installed[name].status!r}, not configured (ii) -- configure or '
                               'reinstall it'))

    lines = []
    for name in sorted(pool):
        p = pool[name]
        how = chosen.get(name)
        if how == 'INSTALL':
            lines.append(f'INSTALL\t{p.path}\t{name}\t{p.version}')
        elif how == 'UPGRADE':
            lines.append(f'UPGRADE\t{p.path}\t{name}\t{installed[name].version}\t{p.version}')
        elif name in installed:
            if configured(installed[name]):
                lines.append(f'KEEP\t{name}\t{installed[name].version}\t{p.version}')
        else:
            lines.append(f'UNUSED\t{p.path}\t{name}\tnothing the roots reach needs it')
    for owner, why in need:
        lines.append(f'NEED\t{owner}\t{why}')
    return lines, need


def run(pool_dir, roots, allow, admindir, out=sys.stdout):
    """print the plan for a pool and return its exit code"""
    pool, dupes = read_pool(pool_dir)
    installed = read_installed(admindir)
    lines, need = plan(pool, installed, roots, set(allow))
    for p in dupes:
        lines.append(f'UNUSED\t{p.path}\t{p.name}\tan older duplicate of {pool[p.name].version}')
    for line in lines:
        print(line, file=out)
    counts = {}
    for line in lines:
        counts[line.split('\t', 1)[0]] = counts.get(line.split('\t', 1)[0], 0) + 1
    print('deb-pool-plan: ' + ' '.join(f'{k}={counts.get(k, 0)}' for k in
          ('INSTALL', 'UPGRADE', 'KEEP', 'UNUSED', 'NEED')), file=sys.stderr)
    return 1 if need else 0


def verify(plan_path, admindir, out=sys.stdout):
    """check a plan file against the installed packages"""
    installed = read_installed(admindir)
    with open(plan_path) as f:
        rows = [ln.rstrip('\n').split('\t') for ln in f if ln.strip()]
    bad, checked = [], 0
    if not any(r[0] in ('INSTALL', 'UPGRADE', 'KEEP', 'UNUSED') for r in rows):
        bad.append(('<plan>', f'{plan_path} holds no plan rows'))
    for r in rows:
        if r[0] in ('INSTALL', 'UPGRADE') and len(r) >= 4:
            checked += 1
            name, want = r[2], r[-1]
            p = installed.get(name)
            if p is None:
                bad.append((name, f'planned {r[0]} {want}, but it is not installed'))
            elif p.version != want:
                bad.append((name, f'planned {r[0]} {want}, but this host has {p.version}'))
            elif p.status != 'ii':
                bad.append((name, f'{want} is in dpkg state {p.status!r}, not configured (ii)'))
        elif r[0] == 'KEEP' and len(r) >= 3:
            checked += 1
            name, had = r[1], r[2]
            p = installed.get(name)
            if p is None:
                bad.append((name, f'had {had} before staging and is gone now'))
            elif p.version != had:
                bad.append((name, f'had {had} before staging and has {p.version} now'))
            elif not configured(p):
                bad.append((name, f'kept at {had}, but it is in dpkg state {p.status!r}, '
                                  'not configured (ii)'))
    for name, why in bad:
        print(f'VERIFY-FAIL\t{name}\t{why}', file=out)
    print(f'deb-pool-plan verify: {checked} row(s) checked, {len(bad)} failed', file=sys.stderr)
    return 1 if bad else 0


def _deb(d, name, version, depends=None, provides=None, pre=None):
    """build a stub .deb with the given relations under a folder"""
    root = os.path.join(d, 'src', f'{name}_{version}')
    os.makedirs(os.path.join(root, 'DEBIAN'))
    ctl = [f'Package: {name}', f'Version: {version}', 'Architecture: all',
           'Maintainer: selftest <selftest@invalid>']
    if pre:
        ctl.append(f'Pre-Depends: {pre}')
    if depends:
        ctl.append(f'Depends: {depends}')
    if provides:
        ctl.append(f'Provides: {provides}')
    ctl.append('Description: selftest fixture')
    with open(os.path.join(root, 'DEBIAN', 'control'), 'w') as f:
        f.write('\n'.join(ctl) + '\n')
    subprocess.run(['dpkg-deb', '-Znone', '--build', root,
                    os.path.join(d, 'pool', f'{name}_{version}_all.deb')],
                   check=True, stdout=subprocess.DEVNULL)


def _status(d, pkgs):
    """write a dpkg status file for the given packages"""
    os.makedirs(os.path.join(d, 'admin'), exist_ok=True)
    with open(os.path.join(d, 'admin', 'status'), 'w') as f:
        for name, version, extra in pkgs:
            extra = dict(extra)
            status = extra.pop('Status', 'install ok installed')
            f.write(f'Package: {name}\nStatus: {status}\nVersion: {version}\n'
                    f'Architecture: all\nMaintainer: selftest <selftest@invalid>\n')
            for k, v in extra.items():
                f.write(f'{k}: {v}\n')
            f.write('Description: selftest fixture\n\n')


def selftest():
    """test plan and verify on fixture pools"""
    bad = 0

    def check(label, cond, detail=''):
        """print a selftest line and count failures"""
        nonlocal bad
        if cond:
            print(f'SELFTEST OK: {label}')
        else:
            bad += 1
            print(f'SELFTEST FAIL: {label} {detail}')

    def case(pool_debs, status, roots, allow=()):
        """run the planner on a stub pool and status"""
        d = tempfile.mkdtemp(prefix='deb-pool-plan-')
        os.makedirs(os.path.join(d, 'pool'))
        for args in pool_debs:
            _deb(d, *args)
        _status(d, status)
        buf = io.StringIO()
        rc = run(os.path.join(d, 'pool'), roots, allow, os.path.join(d, 'admin'), out=buf)
        shutil.rmtree(d)
        rows = [ln.split('\t') for ln in buf.getvalue().splitlines()]
        return rc, rows

    def kinds(rows, kind):
        """return the names in rows of a kind"""
        return {r[2] if kind in ('INSTALL', 'UPGRADE', 'UNUSED') else r[1] for r in rows if r[0] == kind}

    def needs(rows):
        """return the NEED rows as name and reason lines"""
        return [f'{r[1]}: {r[2]}' for r in rows if r[0] == 'NEED']

    base = [('systemd', '255.4-1ubuntu8.16', {'Provides': 'systemd-sysusers (= 255.4-1ubuntu8.16)',
                                                'Depends': 'libsystemd0 (= 255.4-1ubuntu8.16)'}),
            ('libsystemd0', '255.4-1ubuntu8.16', {}),
            ('libudev1', '255.4-1ubuntu8.16', {}),
            ('udev', '255.4-1ubuntu8.16', {'Depends': 'libudev1 (= 255.4-1ubuntu8.16)'}),
            ('libc6', '2.39-0ubuntu8.8', {}),
            ('dbus', '1.14.10-4ubuntu4.1', {'Provides': 'default-dbus-system-bus'})]
    sway_pool = [('sway', '1.9-1build2', 'libc6 (>= 2.38), libseat1, libsystemd0 (>= 243), libudev1 (>= 183)'),
                 ('libseat1', '0.8.0-1', 'default-dbus-system-bus | dbus-system-bus, '
                                         'systemd | systemd-standalone-sysusers | systemd-sysusers'),
                 ('systemd', '255.4-1ubuntu8.17', 'libsystemd0 (= 255.4-1ubuntu8.17)', 'systemd-sysusers'),
                 ('libsystemd0', '255.4-1ubuntu8.17'),
                 ('libudev1', '255.4-1ubuntu8.17'),
                 ('libc6', '2.39-0ubuntu8.8'),
                 ('dbus-broker', '35-2ubuntu0.1', 'libsystemd0 (>= 243)', 'dbus-system-bus'),
                 ('opensysusers', '0.7.3-2', None, 'systemd-sysusers'),
                 ('systemd-standalone-sysusers', '255.4-1ubuntu8.17', None, 'systemd-sysusers')]
    rc, rows = case(sway_pool, base, ['sway'])
    check('the compositor pool installs only what the host lacks',
          rc == 0 and kinds(rows, 'INSTALL') == {'sway', 'libseat1'}, f'rc={rc} rows={rows}')
    check('the host keeps its own systemd stack and libc6, whatever version the pool carries',
          kinds(rows, 'KEEP') == {'systemd', 'libsystemd0', 'libudev1', 'libc6'}, f'rows={rows}')
    check('no UPGRADE line without --allow-upgrade', not kinds(rows, 'UPGRADE'), f'rows={rows}')
    check('alternatives for providers the host already has are never pulled',
          {'dbus-broker', 'opensysusers', 'systemd-standalone-sysusers'} <= kinds(rows, 'UNUSED'),
          f'rows={rows}')

    rc, rows = case([('libglib2.0-bin', '2.80.0-6ubuntu3.9')],
                    [('libglib2.0-bin', '2.80.0-6ubuntu3.8', {})], ['libglib2.0-bin'])
    check('an installed root is satisfied at any version, never upgraded',
          rc == 0 and kinds(rows, 'KEEP') == {'libglib2.0-bin'} and not kinds(rows, 'INSTALL'),
          f'rc={rc} rows={rows}')

    half = {'Status': 'install ok half-configured'}
    rc, rows = case([('libglib2.0-bin', '2.80.0-6ubuntu3.9')],
                    [('libglib2.0-bin', '2.80.0-6ubuntu3.8', half)], ['libglib2.0-bin'])
    n = needs(rows)
    check('a half-configured (iF) root in the pool is a NEED, never a KEEP',
          rc == 1 and not kinds(rows, 'KEEP') and any(x.startswith('libglib2.0-bin:') and "'iF'" in x for x in n),
          f'rc={rc} rows={rows}')
    rc, rows = case([('sway', '1.9', 'libc6')],
                    [('grim', '1.4', {'Status': 'install ok unpacked'}), ('libc6', '2.39', {})], ['sway', 'grim'])
    n = needs(rows)
    check('an unpacked (iU) root outside the pool is a NEED',
          rc == 1 and any(x.startswith('grim:') and "'iU'" in x for x in n), f'rc={rc} need={n}')
    half_base = [(nm, v, half) if nm == 'libudev1' else (nm, v, e) for nm, v, e in base]
    rc, rows = case(sway_pool, half_base, ['sway'])
    n = needs(rows)
    check('a half-configured (iF) package a root depends on is a NEED, never a KEEP',
          rc == 1 and 'libudev1' not in kinds(rows, 'KEEP')
          and any(x.startswith('libudev1:') and "'iF'" in x for x in n)
          and any(x.startswith('sway:') and 'not configured' in x for x in n), f'rc={rc} need={n}')

    polkit_pool = [('gnome-shell', '46.0', 'gir1.2-polkit-1.0'),
                   ('gir1.2-polkit-1.0', '124-2ubuntu1.24.04.4',
                    'libpolkit-agent-1-0 (= 124-2ubuntu1.24.04.4)'),
                   ('libpolkit-agent-1-0', '124-2ubuntu1.24.04.4'),
                   ('polkitd', '124-2ubuntu1.24.04.4', 'libpolkit-agent-1-0 (= 124-2ubuntu1.24.04.4)')]
    polkit_base = [('libpolkit-agent-1-0', '124-2ubuntu1.24.04.3', {}),
                   ('polkitd', '124-2ubuntu1.24.04.3',
                    {'Depends': 'libpolkit-agent-1-0 (= 124-2ubuntu1.24.04.3)'})]
    rc, rows = case(polkit_pool, polkit_base, ['gnome-shell'])
    n = needs(rows)
    check('a kept package needing a newer installed library fails by name',
          rc == 1 and any(x.startswith('gir1.2-polkit-1.0:') and 'libpolkit-agent-1-0 124-2ubuntu1.24.04.3' in x
                          for x in n), f'rc={rc} need={n}')
    check('the refused upgrade is not in the install set',
          not kinds(rows, 'UPGRADE') and 'libpolkit-agent-1-0' not in kinds(rows, 'INSTALL'), f'rows={rows}')

    rc, rows = case(polkit_pool, polkit_base, ['gnome-shell'], allow=['libpolkit-agent-1-0'])
    n = needs(rows)
    check('an allowed upgrade that breaks an installed package fails naming that package',
          rc == 1 and any(x.startswith('polkitd:') and 'upgrading libpolkit-agent-1-0 breaks' in x for x in n),
          f'rc={rc} need={n}')

    rc, rows = case(polkit_pool, polkit_base, ['gnome-shell'], allow=['libpolkit-agent-1-0', 'polkitd'])
    check('an allowed lockstep set upgrades together and plans clean',
          rc == 0 and kinds(rows, 'UPGRADE') == {'libpolkit-agent-1-0', 'polkitd'}
          and kinds(rows, 'INSTALL') == {'gnome-shell', 'gir1.2-polkit-1.0'}, f'rc={rc} rows={rows}')

    rc, rows = case([('sway', '1.9', 'libwlroots12t64')], [], ['sway', 'grim'])
    n = needs(rows)
    check('a dependency neither the host nor the pool provides fails by name',
          rc == 1 and any(x.startswith('sway:') and 'libwlroots12t64' in x for x in n), f'need={n}')
    check('a root neither the host nor the pool provides fails by name',
          any(x.startswith('grim:') for x in n), f'need={n}')

    rc, rows = case([('a', '1', 'virt (>= 2)'), ('b', '1', None, 'virt (= 3)')],
                    [('c', '1', {'Provides': 'virt'})], ['a'])
    check('an unversioned Provides never satisfies a versioned dependency',
          rc == 0 and kinds(rows, 'INSTALL') == {'a', 'b'}, f'rc={rc} rows={rows}')

    rc, sway_rows = case(sway_pool, base, ['sway'])
    plan_text = '\n'.join('\t'.join(r) for r in sway_rows) + '\n'

    def verify_case(status):
        """verify the plan against a status file"""
        d = tempfile.mkdtemp(prefix='deb-pool-verify-')
        _status(d, status or base)
        with open(os.path.join(d, 'plan.tsv'), 'w') as f:
            f.write(plan_text if status is not None else '')
        buf = io.StringIO()
        vrc = verify(os.path.join(d, 'plan.tsv'), os.path.join(d, 'admin'), out=buf)
        shutil.rmtree(d)
        return vrc, [ln.split('\t') for ln in buf.getvalue().splitlines()]

    staged = base + [('sway', '1.9-1build2', {}), ('libseat1', '0.8.0-1', {})]
    vrc, vrows = verify_case(staged)
    check('--verify passes a host that holds exactly the plan', vrc == 0 and not vrows, f'rc={vrc} {vrows}')
    moved = [(n, '255.4-1ubuntu8.17', e) if n == 'libudev1' else (n, v, e) for n, v, e in staged]
    vrc, vrows = verify_case(moved)
    check('--verify names a kept package that staging upgraded (the systemd defect)',
          vrc == 1 and any(r[1] == 'libudev1' and 'has 255.4-1ubuntu8.17 now' in r[2] for r in vrows), f'{vrows}')
    unpacked = [(n, v, {'Status': 'install ok unpacked'}) if n == 'sway' else (n, v, e) for n, v, e in staged]
    vrc, vrows = verify_case(unpacked)
    check('--verify names a planned package left unpacked, not configured',
          vrc == 1 and any(r[1] == 'sway' and 'not configured' in r[2] for r in vrows), f'{vrows}')
    half_kept = [(n, v, half) if n == 'libudev1' else (n, v, e) for n, v, e in staged]
    vrc, vrows = verify_case(half_kept)
    check('--verify names a KEEP package left half-configured (iF)',
          vrc == 1 and any(r[1] == 'libudev1' and 'not configured' in r[2] for r in vrows), f'{vrows}')
    vrc, vrows = verify_case(base)
    check('--verify names a planned package that never got installed',
          vrc == 1 and {r[1] for r in vrows} == {'sway', 'libseat1'}, f'{vrows}')
    vrc, vrows = verify_case(None)
    check('--verify fails an empty plan rather than passing it',
          vrc == 1 and any(r[1] == '<plan>' for r in vrows), f'{vrows}')

    print(f'deb-pool-plan selftest: {"FAIL" if bad else "OK"} ({bad} failed)')
    return 1 if bad else 0


def main():
    """run the planner, verifier or selftest"""
    ap = argparse.ArgumentParser(
        description=__doc__.split('\n')[0], formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='output, one tab-separated line per decision:\n'
               '  INSTALL  <file> <package> <version>              new to this host\n'
               '  UPGRADE  <file> <package> <installed> <pool>     allowed by --allow-upgrade\n'
               '  KEEP     <package> <installed> <pool>            the host\'s copy stays\n'
               '  UNUSED   <file> <package> <why>                  nothing needs it\n'
               '  NEED     <package> <why>                         the plan cannot be installed\n'
               '--verify prints VERIFY-FAIL <package> <why> for a package dpkg -i moved or left unconfigured.\n'
               'exit status: 0 no NEED (or a clean --verify), 1 a NEED or VERIFY-FAIL, 2 usage or I/O error')
    ap.add_argument('--pool', metavar='DIR', help='the staged pool of .debs to plan from')
    ap.add_argument('--root', metavar='PKG', action='append', default=[],
                    help='a package to install with what it depends on; repeatable')
    ap.add_argument('--allow-upgrade', metavar='PKG', action='append', default=[],
                    help='let the plan upgrade this installed package; repeatable, or comma-separated')
    ap.add_argument('--admindir', metavar='DIR', help="the dpkg database to read (default: dpkg's own)")
    ap.add_argument('--verify', metavar='PLAN',
                    help='after dpkg -i ran PLAN, check every INSTALL/UPGRADE package is configured at the '
                         'pool version and every KEEP package is unchanged')
    ap.add_argument('--selftest', action='store_true', help='run the built-in tests')
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    try:
        if a.verify:
            return verify(a.verify, a.admindir)
        if not a.pool or not a.root:
            ap.print_usage(sys.stderr)
            return 2
        allow = [x for item in a.allow_upgrade for x in item.replace(',', ' ').split()]
        return run(a.pool, a.root, allow, a.admindir)
    except OSError as e:
        print(f'deb-pool-plan: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
