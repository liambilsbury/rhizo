#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
DESKD_PATH = os.environ.get(
    "RHIZO_DESKD_PATH", os.path.join(HERE, "..", "..", "..", "..", "src", "services", "deskbridge", "deskd.py"))


def load_deskd():
    """return the deskd module loaded from its file"""
    spec = importlib.util.spec_from_file_location("rhizo_deskd_under_test", DESKD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_icon_pool_bounded(deskd):
    """check that the icon pool stays within its size"""
    with tempfile.TemporaryDirectory(prefix="rhizo-icon-pool-") as tmp:
        pool_size = 4
        pool = deskd.IconPool(tmp, pool_size=pool_size)
        paths = set()
        for i in range(50):
            paths.add(pool.path_for("key-%d" % i))
        if len(paths) > pool_size:
            print("check-deskd-bounds: IconPool handed out %d distinct paths for 50 distinct "
                  "keys, pool_size is %d" % (len(paths), pool_size))
            return False
        if len(pool.slot_by_key) > pool_size or len(pool.key_by_slot) > pool_size:
            print("check-deskd-bounds: IconPool's own bookkeeping grew past pool_size=%d: "
                  "%d keys, %d slots" % (pool_size, len(pool.slot_by_key), len(pool.key_by_slot)))
            return False
    print("check-deskd-bounds: IconPool stayed at %d files for 50 distinct notification keys"
          % pool_size)
    return True


def test_notif_table_bounded(deskd):
    """check that the notification table stays within its capacity"""
    capacity = 8
    table = deskd.NotifTable(capacity=capacity)
    for i in range(100):
        table.put("key-%d" % i, i)
    if len(table) > capacity:
        print("check-deskd-bounds: NotifTable grew to %d entries for 100 distinct "
              "notifications, capacity is %d" % (len(table), capacity))
        return False
    if len(table.id_by_key) != len(table.key_by_id):
        print("check-deskd-bounds: NotifTable's two maps disagree in size: %d vs %d"
              % (len(table.id_by_key), len(table.key_by_id)))
        return False
    print("check-deskd-bounds: NotifTable stayed at %d entries for 100 distinct notifications"
          % capacity)
    return True


def test_relay_queue_bounded(deskd):
    """check that the rhizo-desk-notify queue stays within its limit"""
    inst = object.__new__(deskd.Deskd)
    inst.relay = types.SimpleNamespace(out=deskd.OutQueue(), bus="unix:path=/nonexistent")
    line = len(json.dumps({"t": "close", "id": 4294967295}, separators=(",", ":"))) + 1
    sent = deskd.RELAY_QUEUE_MAX // line + 25
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        for i in range(sent):
            inst.to_relay({"t": "close", "id": 4294967295}, "job-%d" % i)
    held = len(inst.relay.out.buf)
    if held > deskd.RELAY_QUEUE_MAX + line:
        print("check-deskd-bounds: the rhizo-desk-notify queue holds %d bytes after %d requests, "
              "RELAY_QUEUE_MAX is %d" % (held, sent, deskd.RELAY_QUEUE_MAX))
        return False
    if "queue is over" not in buf.getvalue():
        print("check-deskd-bounds: the rhizo-desk-notify queue stayed at its cap, but dropping a request "
              "over it logged nothing")
        return False
    print("check-deskd-bounds: the rhizo-desk-notify queue stayed at RELAY_QUEUE_MAX=%d bytes for %d requests"
          % (deskd.RELAY_QUEUE_MAX, sent))
    return True


def main():
    """run the bounds checks and return the exit code"""
    deskd = load_deskd()
    ok = True
    ok = test_icon_pool_bounded(deskd) and ok
    ok = test_notif_table_bounded(deskd) and ok
    ok = test_relay_queue_bounded(deskd) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
