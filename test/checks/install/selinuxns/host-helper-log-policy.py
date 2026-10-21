#!/usr/bin/env python3
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = "/var/log/rhizo/supervisor.log"
PARENTS = ("init_t", "initrc_t")
HELPERS = (("/usr/bin/kmod", "kmod_t"), ("/usr/bin/mount", "mount_t"), ("/usr/bin/udevadm", "udev_t"))
PIPE_PERMS = ("read", "write", "append", "getattr")


def load_policy_tools():
    """return the udev check's policy module"""
    spec = importlib.util.spec_from_file_location("udev_host_policy", os.path.join(HERE, "udev-host-policy.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def findings(tools, pol, fc, channel):
    """return helper accesses the policy refuses"""
    bad = []
    log_type = tools.file_type(fc, LOG)
    if log_type != "var_log_t":
        bad.append("file_contexts types %s as %r, not var_log_t" % (LOG, log_type))
    for program, domain in HELPERS:
        exec_type = tools.file_type(fc, program)
        if not exec_type:
            bad.append("file_contexts gives %s no type" % program)
            continue
        for parent in PARENTS:
            if pol.transition(parent, exec_type, "process") != domain:
                bad.append("%s running %s (%s) does not enter %s" % (parent, program, exec_type, domain))
            if channel == "pipe":
                for perm in PIPE_PERMS:
                    if not pol.allowed(domain, parent, "fifo_file", perm):
                        bad.append("%s may not %s a pipe made by %s" % (domain, perm, parent))
                if not pol.allowed(domain, parent, "fd", "use"):
                    bad.append("%s may not use a descriptor inherited from %s" % (domain, parent))
            elif not pol.allowed(domain, log_type, "file", "append"):
                bad.append("%s may not append %s (%s)" % (domain, LOG, log_type))
    return bad


SYSCALL_MOUNT = (("capability", "init_t", "sys_admin"), ("dir", "var_run_t", "mounton"), ("dir", "var_lib_t", "mounton"),
                 ("filesystem", "fs_t", "unmount"), ("filesystem", "fs_t", "mount"), ("filesystem", "var_lib_t", "unmount"),
                 ("filesystem", "tmpfs_t", "unmount"), ("filesystem", "var_run_t", "unmount"))
USERDEL_DOMAIN = "useradd_t"
USERDEL_CALLERS = ("init_t", "dpkg_script_t", "dpkg_t")


def mount_syscall_findings(pol):
    """return mount and umount rights init_t lacks"""
    bad = []
    for cls, target, perm in SYSCALL_MOUNT:
        if not pol.allowed("init_t", target, cls, perm):
            bad.append("init_t may not %s on %s:%s" % (perm, target, cls))
    return bad


def userdel_findings(tools, pol, fc):
    """return reasons the userdel denial is not stock"""
    bad = []
    exec_type = tools.file_type(fc, "/usr/sbin/userdel")
    if not exec_type:
        bad.append("file_contexts gives /usr/sbin/userdel no type")
    else:
        for caller in USERDEL_CALLERS:
            if pol.transition(caller, exec_type, "process") != USERDEL_DOMAIN:
                bad.append("%s running userdel (%s) does not enter %s" % (caller, exec_type, USERDEL_DOMAIN))
    if pol.allowed(USERDEL_DOMAIN, USERDEL_DOMAIN, "capability", "sys_ptrace"):
        bad.append("%s may sys_ptrace" % USERDEL_DOMAIN)
    return bad


def selftest(tools, pol, fc):
    """check the pipe passes and the file fails"""
    bad = []
    got = findings(tools, pol, fc, "pipe") + mount_syscall_findings(pol) + userdel_findings(tools, pol, fc)
    if got:
        bad.append("the pipe channel has findings: %r" % got)
    got = findings(tools, pol, fc, "file")
    for _program, domain in HELPERS:
        if not any("%s may not append" % domain in g for g in got):
            bad.append("the log file append by %s was not refused: %r" % (domain, got))
    return bad


def main():
    """run the check or its selftest"""
    tools = load_policy_tools()
    for need in (tools.DEB, tools.PP):
        if not os.path.exists(need):
            print("FAIL %s is missing (tools/fetch/host-policy.sh fetches the policy)" % need)
            return 1
    with tempfile.TemporaryDirectory() as work:
        policy, fc = tools.build_policy(work)
        pol = tools.Policy(policy)
        if "--selftest" in sys.argv[1:]:
            bad = selftest(tools, pol, fc)
        else:
            bad = findings(tools, pol, fc, "pipe") + mount_syscall_findings(pol) + userdel_findings(tools, pol, fc)
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
