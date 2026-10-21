#!/usr/bin/env python3
# print the share and android uri of a host path
import json, os, sys, urllib.parse
try:
    doc = json.loads(sys.argv[1])
except ValueError as e:
    print("ERR hostfs.py status --json did not print JSON: %s" % e)
    raise SystemExit(0)
path = sys.argv[2]
for share in doc.get("shares", []):
    host_dir = os.path.realpath(share["host_dir"])
    if path == host_dir or path.startswith(host_dir + os.sep):
        rel = os.path.relpath(path, host_dir)
        print("%s\t%s\tfile:///storage/emulated/0/%s"
              % (share["name"], rel, urllib.parse.quote(share["name"] + "/" + rel, safe="/")))
        break
