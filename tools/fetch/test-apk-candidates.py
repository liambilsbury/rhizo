#!/usr/bin/env python3
# print the F-Droid index's test APK candidates, smallest first
import json, sys

DANGEROUS = {
    "android.permission.READ_CALENDAR","android.permission.WRITE_CALENDAR",
    "android.permission.CAMERA",
    "android.permission.READ_CONTACTS","android.permission.WRITE_CONTACTS","android.permission.GET_ACCOUNTS",
    "android.permission.ACCESS_FINE_LOCATION","android.permission.ACCESS_COARSE_LOCATION","android.permission.ACCESS_BACKGROUND_LOCATION",
    "android.permission.RECORD_AUDIO",
    "android.permission.READ_PHONE_STATE","android.permission.READ_PHONE_NUMBERS","android.permission.CALL_PHONE",
    "android.permission.ANSWER_PHONE_CALLS","android.permission.READ_CALL_LOG","android.permission.WRITE_CALL_LOG",
    "android.permission.ADD_VOICEMAIL","android.permission.USE_SIP","android.permission.PROCESS_OUTGOING_CALLS",
    "android.permission.BODY_SENSORS","android.permission.BODY_SENSORS_BACKGROUND",
    "android.permission.SEND_SMS","android.permission.RECEIVE_SMS","android.permission.READ_SMS",
    "android.permission.RECEIVE_WAP_PUSH","android.permission.RECEIVE_MMS",
    "android.permission.READ_EXTERNAL_STORAGE","android.permission.WRITE_EXTERNAL_STORAGE","android.permission.MANAGE_EXTERNAL_STORAGE",
    "android.permission.ACCESS_MEDIA_LOCATION","android.permission.READ_MEDIA_IMAGES","android.permission.READ_MEDIA_VIDEO","android.permission.READ_MEDIA_AUDIO",
    "android.permission.ACTIVITY_RECOGNITION",
    "android.permission.BLUETOOTH_ADVERTISE","android.permission.BLUETOOTH_SCAN","android.permission.BLUETOOTH_CONNECT",
    "android.permission.NEARBY_WIFI_DEVICES",
    "android.permission.POST_NOTIFICATIONS",
}

with open(sys.argv[1]) as f:
    d = json.load(f)

cands = []
for pkgname, pdata in d["packages"].items():
    versions = pdata.get("versions", {})
    if not versions:
        continue
    best = max(versions.values(), key=lambda v: v.get("manifest", {}).get("versionCode", 0))
    manifest = best.get("manifest", {})
    if manifest.get("nativecode"):
        continue
    meta = pdata.get("metadata", {})
    text = (pkgname + " " + str(meta.get("summary", {})) + " " + str(meta.get("description", {}))).lower()
    if "shortcut" in text or "does not have its own" in text:
        continue
    if "solid colour" in text or "solid color" in text or "red screen" in text or "blank screen" in text:
        continue
    if pkgname in ("com.page.bizzle", "io.github.ebraminio.bouncy"):
        continue
    if "Launcher" in meta.get("categories", []) or pkgname.endswith("launcher") or "launcher" in pkgname.split(".")[-1].lower():
        continue
    if pkgname in ("com.termux.boot", "com.oF2pks.neolinker", "com.simonramstedt.yoke",
                   "at.or.at.plugoffairplane", "com.dasp.worldcup2026", "org.droidtr.termbin",
                   "net.basov.lws.qr.fdroid"):
        continue
    if pkgname == "com.quaap.phonefonefun":
        continue
    if manifest.get("usesSdk", {}).get("targetSdkVersion", 0) < 26:
        continue
    perms = {p.get("name") for p in manifest.get("usesPermission", [])}
    if perms & DANGEROUS:
        continue
    size = best.get("file", {}).get("size", 0)
    if size <= 0 or size >= 8 * 1024 * 1024:
        continue
    fname = best.get("file", {}).get("name")
    sha = best.get("file", {}).get("sha256")
    if not fname or not sha:
        continue
    cands.append((size, pkgname, fname, sha))

cands.sort()
for size, pkgname, fname, sha in cands:
    print(f"{size}\t{pkgname}\t{fname}\t{sha}")
