#!/usr/bin/env python3
import ast
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")
POLICY_UNIT = os.path.join(HERE, "..", "..", "..", "..", "src", "services", "units", "boot", "policy.service")


def load_launcher():
    """return the launcher module loaded from its file"""
    if os.path.dirname(LAUNCHER) not in sys.path:
        sys.path.insert(0, os.path.dirname(LAUNCHER))
    spec = importlib.util.spec_from_file_location("_l3_shutdown_reap", LAUNCHER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def wait_gone(proc, budget=5.0):
    """return whether a process exits within a time budget"""
    deadline = time.time() + budget
    while proc.poll() is None and time.time() < deadline:
        time.sleep(0.05)
    return proc.poll() is not None


def exec_stop_verb(unit_text):
    """return the verb in the ExecStop line"""
    verb = None
    for line in unit_text.splitlines():
        line = line.strip()
        if not line.startswith("ExecStop="):
            continue
        parts = line[len("ExecStop="):].split()
        for i, p in enumerate(parts):
            if p.endswith("launcher3.py") and i + 1 < len(parts):
                verb = parts[i + 1]
    return verb


def dispatched_function(tree, verb):
    """return the function the verb calls"""
    for node in ast.walk(tree):
        if not isinstance(node, ast.If):
            continue
        if not any(isinstance(n, ast.Compare) and len(n.ops) == 1 and isinstance(n.ops[0], ast.Eq)
                   and isinstance(n.comparators[0], ast.Constant) and n.comparators[0].value == verb
                   for n in ast.walk(node.test)):
            continue
        for stmt in node.body:
            if not (isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call)):
                continue
            call = stmt.value
            if not (isinstance(call.func, ast.Attribute) and call.func.attr == "exit"
                    and isinstance(call.func.value, ast.Name) and call.func.value.id == "sys"):
                continue
            if call.args and isinstance(call.args[0], ast.Call) and isinstance(call.args[0].func, ast.Name):
                return call.args[0].func.id
    return None


def function_calls(tree, func_name, target_name):
    """check a function body for a named call"""
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == func_name:
            return any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == target_name
                       for n in ast.walk(node))
    return None


def check_shutdown_reap_wiring(bad):
    """record a problem for each way the shutdown reap is not wired"""
    try:
        unit_text = open(POLICY_UNIT).read()
    except OSError as e:
        bad.append("could not read %s (%s)" % (POLICY_UNIT, e))
        return
    verb = exec_stop_verb(unit_text)
    if not verb:
        bad.append("rhizo-policy.service has no ExecStop= naming a launcher3.py verb")
        return
    tree = ast.parse(open(LAUNCHER).read())
    fn = dispatched_function(tree, verb)
    if not fn:
        bad.append("no __main__ dispatch in launcher3.py routes argv[1] == %r to a function" % verb)
        return
    calls = function_calls(tree, fn, "reap_resident_supervisor_if_shutting_down")
    if calls is None:
        bad.append("%s(), dispatched from rhizo-policy.service's ExecStop, is not defined" % fn)
    elif not calls:
        bad.append("%s() does not call reap_resident_supervisor_if_shutting_down()" % fn)
    if function_calls(tree, "androidd_stop", "reap_resident_supervisor_if_shutting_down"):
        bad.append("androidd_stop() still calls reap_resident_supervisor_if_shutting_down()")


def main():
    """run the shutdown reap checks"""
    bad = []
    try:
        mod = load_launcher()
    except Exception as e:                                  # noqa: BLE001
        print("FAIL: src/androidd/boot.py would not import (%s)" % e)
        return 1

    for name in ("reap_resident_supervisor_if_shutting_down", "system_is_shutting_down"):
        if not hasattr(mod, name):
            bad.append("%s() not found in src/androidd/boot.py" % name)
    if bad:
        for b in bad:
            print("FAIL: %s" % b)
        return 1

    check_shutdown_reap_wiring(bad)
    if bad:
        for b in bad:
            print("FAIL: %s" % b)
        return 1

    with tempfile.TemporaryDirectory() as d:
        pid_file = os.path.join(d, "rhizo_g_pid")

        def new_supervisor():
            """start a sleeping supervisor process and write its pid file"""
            proc = subprocess.Popen(["sleep", "50"])
            with open(pid_file, "w") as f:
                f.write(mod.supervisor_record(proc.pid))
            return proc

        mod.G_PID_FILE = pid_file
        mod.RHIZO_RESIDENT_G = True

        proc = new_supervisor()
        mod.reap_resident_supervisor_if_shutting_down(shutting_down=lambda: False)
        time.sleep(0.2)
        if proc.poll() is not None:
            bad.append("an ordinary stop (system running) killed the resident supervisor")
        proc.kill()
        proc.wait()

        proc = new_supervisor()
        mod.reap_resident_supervisor_if_shutting_down(shutting_down=lambda: True)
        if not wait_gone(proc):
            bad.append("a real shutdown did not end the resident supervisor")
            proc.kill()
        proc.wait()

        mod.RHIZO_RESIDENT_G = False
        proc = new_supervisor()
        mod.reap_resident_supervisor_if_shutting_down(shutting_down=lambda: True)
        time.sleep(0.2)
        if proc.poll() is not None:
            bad.append("a shutdown with resident dispatch off still killed a recorded process")
        proc.kill()
        proc.wait()

    def fake_run(stdout):
        """return a run function that answers with a fixed output"""
        def run(argv, **kw):
            """record an unexpected command and return the fixed output"""
            if argv != ["systemctl", "is-system-running"]:
                bad.append("system_is_shutting_down() ran %r, not systemctl is-system-running" % (argv,))
            return types.SimpleNamespace(stdout=stdout)
        return run

    if mod.system_is_shutting_down(run=fake_run(b"running\n")) is not False:
        bad.append("system_is_shutting_down() read 'running' as a shutdown")
    if mod.system_is_shutting_down(run=fake_run(b"stopping\n")) is not True:
        bad.append("system_is_shutting_down() did not read 'stopping' as a shutdown")
    if mod.system_is_shutting_down(run=fake_run(b"degraded\n")) is not False:
        bad.append("system_is_shutting_down() read 'degraded' as a shutdown")

    def raising_run(argv, **kw):
        """raise an error as if the command were missing"""
        raise OSError("systemctl not found")

    if mod.system_is_shutting_down(run=raising_run) is not False:
        bad.append("a failed systemctl call was read as a shutdown")

    for b in bad:
        print("FAIL: %s" % b)
    if not bad:
        print("check-resident-supervisor-shutdown-reap: the resident supervisor is SIGKILLed only "
              "when systemctl is-system-running answers 'stopping', and left alone on an ordinary "
              "stop or when resident dispatch is off")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
