#!/usr/bin/env python3
# 导出 mutter DisplayConfig 里每个 monitor 的原始 spec（尤其 vendor/product/serial），
# 供「把触摸设备直接绑定到主屏输出」方案使用。
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

BUS = "org.gnome.Mutter.DisplayConfig"
PATH = "/org/gnome/Mutter/DisplayConfig"

proxy = Gio.DBusProxy.new_for_bus_sync(
    Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None, BUS, PATH, BUS, None
)
ret = proxy.call_sync("GetCurrentState", None, Gio.DBusCallFlags.NONE, -1, None)
serial, monitors, logical, props = ret.unpack()

print("serial =", serial)
print("== monitors ==")
for m in monitors:
    # m 结构: (spec, modes, properties)
    spec = m[0]
    # spec: (connector, product?, ...)
    print("  --- monitor ---")
    for idx, item in enumerate(spec):
        try:
            v = item.unpack() if hasattr(item, "unpack") else item
        except Exception:
            v = item
        print(f"    spec[{idx}] = {v!r}")
    mp = m[2]
    try:
        d = mp.unpack() if hasattr(mp, "unpack") else mp
        for k, val in d.items():
            try:
                print(f"    prop {k} = {val.unpack()!r}")
            except Exception:
                print(f"    prop {k} = {val!r}")
    except Exception as e:
        print("    prop parse err:", e)

print("== logical monitors ==")
for lm in logical:
    print("   ", lm[0], lm[1], lm[2], lm[3], lm[4] if len(lm) > 4 else "")
