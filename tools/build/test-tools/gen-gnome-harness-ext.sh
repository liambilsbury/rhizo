#!/bin/bash
# write the GNOME harness extension.js
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
OUT_DIR="../../../test/system/guest/gnome-harness-ext/rhizo-harness@rhizo"
mkdir -p "$OUT_DIR"

cat > "$OUT_DIR/extension.js" <<'RHIZO_GNOME_EXT_EOF'
// SPDX-License-Identifier: GPL-2.0-or-later
// GNOME harness extension: exports window, seat and notification state over D-Bus
'use strict';

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Clutter from 'gi://Clutter';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

// org.rhizo.Harness interface
const IFACE_XML = `
<node>
  <interface name="org.rhizo.Harness">
    <method name="Ping">
      <arg type="s" direction="out" name="info"/>
    </method>
    <method name="GetPointer">
      <arg type="s" direction="out" name="pointer_json"/>
    </method>
    <method name="GetWindows">
      <arg type="s" direction="out" name="windows_json"/>
    </method>
    <method name="WindowOp">
      <arg type="u" direction="in" name="id"/>
      <arg type="s" direction="in" name="op"/>
      <arg type="s" direction="in" name="args_json"/>
    </method>
    <method name="GetSeatDevices">
      <arg type="s" direction="out" name="devices_json"/>
    </method>
    <method name="GetNotifications">
      <arg type="s" direction="out" name="notifications_json"/>
    </method>
    <method name="ActivateNotification">
      <arg type="s" direction="in" name="id"/>
      <arg type="s" direction="in" name="key"/>
      <arg type="b" direction="out" name="invoked"/>
    </method>
  </interface>
</node>`;

const BUS_NAME = 'org.rhizo.Harness';
const OBJECT_PATH = '/org/rhizo/Harness';

export default class RhizoHarnessExtension extends Extension {
  enable() {
    this._dbusImpl = Gio.DBusExportedObject.wrapJSObject(IFACE_XML, this);
    this._dbusImpl.export(Gio.DBus.session, OBJECT_PATH);
    this._ownerId = Gio.bus_own_name(
      Gio.BusType.SESSION, BUS_NAME, Gio.BusNameOwnerFlags.NONE,
      null, null, null);
    // keep the session out of the overview
    Main.layoutManager.startInOverview = false;
    if (Main.layoutManager._startingUp) {
      this._startupId = Main.layoutManager.connect('startup-complete', () => Main.overview.hide());
    } else {
      Main.overview.hide();
    }
  }

  disable() {
    if (this._startupId) {
      Main.layoutManager.disconnect(this._startupId);
      this._startupId = null;
    }
    if (this._ownerId) {
      Gio.bus_unown_name(this._ownerId);
      this._ownerId = null;
    }
    if (this._dbusImpl) {
      this._dbusImpl.unexport();
      this._dbusImpl = null;
    }
  }

  // report the extension version, gnome-shell's pid and the overview state
  Ping() {
    const overview = Main.overview.visible ? 1 : 0;
    return `rhizo-harness 1 pid=${GLib.file_read_link('/proc/self')} overview=${overview}`;
  }

  GetPointer() {
    const [x, y] = global.get_pointer();
    return JSON.stringify({x, y});
  }

  // ---- monitor index <-> connector name -------------------------------
  _connectorForMonitorIndex(index) {
    try {
      const manager = global.backend.get_monitor_manager();
      if (manager && typeof manager.get_monitors === 'function') {
        const monitors = manager.get_monitors();
        if (index >= 0 && index < monitors.length && typeof monitors[index].get_connector === 'function')
          return monitors[index].get_connector();
      }
    } catch (e) {
    }
    return String(index);
  }

  _monitorIndexForConnector(connector) {
    try {
      const manager = global.backend.get_monitor_manager();
      if (manager && typeof manager.get_monitors === 'function') {
        const monitors = manager.get_monitors();
        for (let i = 0; i < monitors.length; i++) {
          if (typeof monitors[i].get_connector === 'function' && monitors[i].get_connector() === connector)
            return i;
        }
      }
    } catch (e) {
    }
    const n = Number(connector);
    return Number.isInteger(n) ? n : -1;
  }

  // ---- windows -------------------------------------------------------

  // a JSON object per mapped window
  GetWindows() {
    const out = [];
    for (const win of global.display.list_all_windows()) {
      if (win.is_override_redirect())
        continue;
      const rect = win.get_frame_rect();
      out.push({
        id: win.get_id(),
        app_id: win.get_wm_class() || '',
        title: win.get_title() || '',
        x: rect.x, y: rect.y, w: rect.width, h: rect.height,
        fullscreen: win.is_fullscreen(),
        maximized: win.get_maximized() === Meta.MaximizeFlags.BOTH,
        focused: win.has_focus(),
        monitor: this._connectorForMonitorIndex(win.get_monitor()),
      });
    }
    return JSON.stringify(out);
  }

  _findWindow(id) {
    for (const win of global.display.list_all_windows()) {
      if (win.get_id() === id)
        return win;
    }
    return null;
  }

  // apply a window operation
  WindowOp(id, op, argsJson) {
    const win = this._findWindow(id);
    if (!win)
      throw new Error(`no window with id ${id}`);
    let args = {};
    if (argsJson) {
      try {
        args = JSON.parse(argsJson);
      } catch (e) {
        throw new Error(`args_json is not valid JSON: ${argsJson}`);
      }
    }
    const now = global.get_current_time();
    switch (op) {
      case 'fullscreen':
        win.make_fullscreen();
        break;
      case 'unfullscreen':
        win.unmake_fullscreen();
        break;
      case 'maximize':
        win.maximize(Meta.MaximizeFlags.BOTH);
        break;
      case 'unmaximize':
        win.unmaximize(Meta.MaximizeFlags.BOTH);
        break;
      case 'move':
        win.move_frame(true, args.x, args.y);
        break;
      case 'resize': {
        const rect = win.get_frame_rect();
        win.move_resize_frame(true, rect.x, rect.y, args.w, args.h);
        break;
      }
      case 'to_monitor':
        win.move_to_monitor(this._monitorIndexForConnector(args.monitor));
        break;
      case 'activate':
        Main.activateWindow(win, now);
        break;
      case 'above':
        win.make_above();
        break;
      case 'close':
        win.delete(now);
        break;
      default:
        throw new Error(`unknown WindowOp op: ${op}`);
    }
  }

  // ---- seat devices ----------------------------------------------------

  GetSeatDevices() {
    const seat = Clutter.get_default_backend().get_default_seat();
    const out = seat.list_devices().map(d => ({
      name: d.get_device_name(),
      device_type: d.get_device_type(),
      vendor_id: d.get_vendor_id ? d.get_vendor_id() : '',
      product_id: d.get_product_id ? d.get_product_id() : '',
    }));
    return JSON.stringify(out);
  }

  // ---- notifications -----------------------------------------------------

  // return this extension's id for a notification
  _notificationId(notif) {
    if (!this._fallbackIds)
      this._fallbackIds = new Map();
    if (!this._fallbackIds.has(notif))
      this._fallbackIds.set(notif, `ext-${this._fallbackIds.size}`);
    return this._fallbackIds.get(notif);
  }

  // return null: the default action is not visible to the extension
  _hasDefaultAction(_notif) {
    return null;
  }

  // return the file the notification's image-path hint named, or ''
  _iconFile(notif) {
    const gicon = notif.gicon;
    if (gicon instanceof Gio.FileIcon)
      return gicon.get_file().get_path() ?? '';
    return '';
  }

  GetNotifications() {
    const out = [];
    for (const source of Main.messageTray.getSources()) {
      for (const notif of source.notifications) {
        out.push({
          id: this._notificationId(notif),
          source: source.title ?? '',
          title: notif.title ?? '',
          body: notif.bannerBodyText ?? notif.body ?? '',
          has_default_action: this._hasDefaultAction(notif),
          icon: this._iconFile(notif),
        });
      }
    }
    return JSON.stringify(out);
  }

  // click a notification
  ActivateNotification(id, key) {
    if (key !== 'default')
      throw new Error(`notification ${id}: only the default action, a click, is reachable through the shell's public API (asked for '${key}')`);
    for (const source of Main.messageTray.getSources()) {
      for (const notif of source.notifications) {
        if (this._notificationId(notif) !== id)
          continue;
        notif.activate();
        return true;
      }
    }
    throw new Error(`no notification with id ${id}`);
  }
}
RHIZO_GNOME_EXT_EOF

echo "[gen-gnome-harness-ext] wrote $OUT_DIR/extension.js ($(wc -l < "$OUT_DIR/extension.js") lines)"
