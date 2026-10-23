#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AM60 显示布局固定器 + 红外触控坐标映射计算

目标：无论开机时接了 1/2/3 个屏，始终把「大屏 OPS 口 HDMI-1」设为
  - 主屏（primary：顶部栏 / dash / 通知 / 新窗口都在这）
  - 放在最左（x=0）
其余口按 HDMI-2 → DP-1 顺序向右排。

并据此算出红外触控框（USB，上报 0..32767 归一化坐标）应该写的
libinput 校准矩阵，写到 ~/.config/am60-touch-matrix 供 root 的
/usr/local/sbin/touchscreen-map.sh 读取生成 udev 规则。

用法:
  am60-monitor-layout.py            # 应用布局 + 写矩阵文件（一次性）
  am60-monitor-layout.py --watch    # 看门狗：常驻监听 MonitorsChanged，主屏非大屏即纠偏
  am60-monitor-layout.py --query    # 只打印当前布局
  am60-monitor-layout.py --dry-run  # 只打印将应用的布局
"""
import os
import sys
import time
import subprocess

try:
    import gi
    gi.require_version('Gio', '2.0')
    from gi.repository import Gio, GLib
except Exception as e:
    sys.stderr.write("需要 python3-gi: %s\n" % e)
    sys.exit(2)

BUS_NAME = 'org.gnome.Mutter.DisplayConfig'
OBJ_PATH = '/org/gnome/Mutter/DisplayConfig'
IFACE = 'org.gnome.Mutter.DisplayConfig'

# 期望的从左到右顺序；不在列表里的口排到最后
# 2026-09-15：内核 Plan B 补丁把 Type-C 口连接器类型从 DisplayPort 改成 HDMIB，
# mutter 名字随之变成 HDMI-B-1；同时保留 DP-1 以便回滚旧内核仍可用。
PREFERRED_ORDER = ['HDMI-1', 'HDMI-2', 'HDMI-B-1', 'DP-1']
MAIN_CONNECTOR = 'HDMI-1'
MATRIX_FILE = os.path.expanduser('~/.config/am60-touch-matrix')


def get_proxy(wait=False):
    """连会话总线。wait=True 时最多等 90 秒（供开机自启动用，
    mutter 的 D-Bus 名在登录早期可能还没起）。"""
    import time
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    deadline = time.time() + 90
    delay = 1.0
    while True:
        try:
            p = Gio.DBusProxy.new_sync(bus, Gio.DBusProxyFlags.NONE, None,
                                       BUS_NAME, OBJ_PATH, IFACE, None)
            p.call_sync('GetCurrentState', None,
                        Gio.DBusCallFlags.NONE, 3000, None)
            return p
        except Exception:
            if not wait or time.time() > deadline:
                raise
            time.sleep(delay)
            delay = min(delay * 1.5, 5.0)


def get_state(proxy):
    """返回 (serial, monitors, logical_monitors)

    monitors: [{connector, vendor, product, serial, current, allmodes, props}]
      current = (mode_id, w, h, refresh, ...) 或 None（mutter 尚未标 current）
      allmodes = [(mode_id, w, h, refresh), ...]  第一个为首选模式
    出现在列表里即表示连接器 connected（mutter 已枚举到）。
    logical_monitors: [{x, y, scale, transform, is_primary, monitors:[connector]}]
    """
    v = proxy.call_sync('GetCurrentState', None,
                        Gio.DBusCallFlags.NONE, -1, None)
    u = v.unpack()                       # unpack() 是递归的，嵌套已是 Python 原生类型
    serial = u[0]
    monitors = []
    for m in u[1]:
        spec, modes, props = m[0], m[1], m[2]
        cur = None
        allmodes = []
        for md in modes:
            mid, w, h, r = md[0], md[1], md[2], md[3]
            allmodes.append((mid, w, h, r))
            md_props = md[6] if len(md) > 6 else {}
            if md_props.get('is-current'):
                cur = md
        monitors.append({
            'connector': spec[0],
            'vendor': spec[1], 'product': spec[2], 'serial': spec[3],
            'current': cur,
            'allmodes': allmodes,
            'props': props or {},
        })
    logical = []
    for lm in u[2]:
        logical.append({
            'x': lm[0], 'y': lm[1], 'scale': lm[2],
            'transform': lm[3], 'is_primary': lm[4],
            'monitors': [mm[0] for mm in lm[5]],
        })
    return serial, monitors, logical


def print_state(serial, monitors, logical):
    print("serial=%s" % serial)
    print("== 物理输出 ==")
    for m in monitors:
        cur = m['current']
        mode = "%dx%d@%.3f" % (cur[1], cur[2], cur[3]) if cur else "(无当前模式)"
        print("  %-10s %-14s %-20s enabled=%s" %
              (m['connector'], m['product'] or '-', mode,
               m['props'].get('is-enabled')))
    print("== 逻辑监视器 ==")
    for lm in logical:
        print("  x=%-5d y=%-4d scale=%-5s primary=%-5s %s" %
              (lm['x'], lm['y'], lm['scale'], lm['is_primary'],
               ','.join(lm['monitors'])))


def ensure_main_ready():
    """大屏 OPS 口（HDMI-A-1）无 HPD，开机/热插拔时 mutter 可能缓存了
    “未配置”状态却不再向 KMS 提交 4K 模式，表现为大屏无信号（逻辑态与
    KMS 实际态失同步）。这里对大屏口做一次 off/on 强制重探测（经由 root
    助手脚本 am60-hdmi-reprobe.sh），逼 mutter 用已就位的 EDID 重新提交
    布局，然后等待模式就绪。
    返回 True 表示已检测到可用模式。"""
    try:
        subprocess.call(['sudo', '-n', '/usr/local/sbin/am60-hdmi-reprobe.sh'],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    modes = '/sys/class/drm/card0-HDMI-A-1/modes'
    ready = False
    for i in range(30):
        try:
            if os.path.getsize(modes) > 0:
                ready = True
                break
        except Exception:
            pass
        time.sleep(1)
    return ready


def order_key(connector):
    base = connector.split('-')[0]
    if connector in PREFERRED_ORDER:
        return (PREFERRED_ORDER.index(connector), connector)
    if base in PREFERRED_ORDER:
        return (100 + PREFERRED_ORDER.index(base), connector)
    return (200, connector)


def build_config(monitors, logical):
    """构造期望布局：HDMI-1 主屏 + 最左，其余按 PREFERRED_ORDER 向右排。

    返回 (cfg, geom)
      cfg  : 可直接喂给 ApplyMonitorsConfig 的 list
      geom : [(connector, x, w, h), ...]  —— 用来算触控矩阵
    """
    # 注意：mutter 46 的 monitor props 里没有 'is-enabled'，
    # 判断"是否真的在用"要看它是否出现在 logical_monitors 里。
    # 出现在 monitors 列表本身即表示连接器 connected（已枚举到）。
    active = set()
    for lm in logical:
        active.update(lm['monitors'])

    def usable(m):
        # 已连接且至少有一个可用模式（current 或首选模式）
        return bool(m['current'] or m.get('allmodes'))

    # ★ 关键修复（重启后 Type-C 抢主屏的根因）：
    # 旧逻辑用 logical_monitors（已"摆放"的口）来判定 enabled，导致刚被
    # ensure_main_ready 在 KMS 层 forceon 的大屏 HDMI-A-1，在 mutter 尚未把它
    # 重新提交进 logical_monitors 的空窗期里被漏掉 → has_main=False → 主屏
    # 落到 DP-1 / HDMI-2。改成以 monitors（真实已连接+有模式）为依据，且
    # 大屏主屏永远强制纳入，不受"是否已在 logical 里"影响（仍保留：非主屏
    # 的口必须已摆放，避免把没真接显示器的口算进来）。
    enabled = [m for m in monitors
               if usable(m) and (m['connector'] in active or m['connector'] == MAIN_CONNECTOR)]
    if not enabled:                         # 退化：所有已连接且有模式的口
        enabled = [m for m in monitors if usable(m)]
    if not enabled:
        return None, []

    enabled.sort(key=lambda m: order_key(m['connector']))

    has_main = any(m['connector'] == MAIN_CONNECTOR for m in enabled)
    cfg, geom = [], []
    x = 0
    for i, m in enumerate(enabled):
        cur = m['current'] or m['allmodes'][0]   # 兜底用首选模式
        w, h = int(cur[1]), int(cur[2])
        mode_id = cur[0]
        if has_main:
            primary = (m['connector'] == MAIN_CONNECTOR)
        else:
            primary = (i == 0)
        cfg.append((x, 0, 1.0, 0, primary, [(m['connector'], mode_id, {})]))
        geom.append((m['connector'], x, w, h))
        x += w
    return cfg, geom


def write_matrix(geom):
    """按主屏 HDMI-1 的几何区间算 libinput 校准矩阵并落盘。

    归一化输入 0..1 → 输出应覆盖 [x/total, (x+w)/total]
        a = w / total      b = 0
        c = x / total      d = 0
        e = 1              f = 0
    """
    if not geom:
        return None
    total = 0
    for _c, _x, w, _h in geom:
        total = max(total, _x + w)
    if total <= 0:
        return None

    main = None
    for c, x, w, h in geom:
        if c == MAIN_CONNECTOR:
            main = (x, w)
            break
    if main is None:
        x, w = 0, total
    else:
        x, w = main

    a = w / float(total)
    c = x / float(total)
    mtx = [a, 0.0, c, 0.0, 1.0, 0.0]

    def fmt(n):
        s = ("%.6f" % n).rstrip('0').rstrip('.')
        return s if s and s != '-0' else '0'

    text = " ".join(fmt(n) for n in mtx)
    changed = True
    try:
        try:
            with open(MATRIX_FILE) as f:
                changed = (f.read().strip() != text)
        except Exception:
            changed = True  # 文件不存在/读不了 → 视为变化，确保写入
        if changed:
            os.makedirs(os.path.dirname(MATRIX_FILE), exist_ok=True)
            with open(MATRIX_FILE, 'w') as f:
                f.write(text + "\n")
    except Exception as e:
        sys.stderr.write("写矩阵文件失败: %s\n" % e)
    return text, changed


def _layout_matches(logical, cfg):
    """检查当前 logical_monitors 是否与期望 cfg 完全一致（每个口的位置和主屏标志）。"""
    expected = {c[5][0][0]: (int(c[0]), bool(c[4])) for c in cfg}
    # 1) 所有期望的口都必须在 logical 里且 x/primary 对得上
    seen = set()
    for lm in logical:
        for conn in lm['monitors']:
            seen.add(conn)
            if conn in expected:
                exp_x, exp_pri = expected[conn]
                if int(lm['x']) != exp_x or bool(lm['is_primary']) != exp_pri:
                    return False
    # 2) 主屏 HDMI-1 必须存在且 primary
    for lm in logical:
        if MAIN_CONNECTOR in lm['monitors']:
            return lm['is_primary']
    return False


def apply_if_needed(proxy):
    """若当前布局（主屏、顺序、位置）与期望不符，则重新应用固定布局。

    用作看门狗：mutter 每次重配置都会发 MonitorsChanged，本函数据此纠偏。
    当布局已完全一致时跳过，避免自我触发的死循环。
    """
    try:
        serial, monitors, logical = get_state(proxy)
    except Exception as e:
        sys.stderr.write("watch get_state 失败: %s\n" % e)
        return
    cfg, geom = build_config(monitors, logical)
    if not cfg:
        return
    # ★ 2026-09-15 修复（防回退）：TV 等口的模式变化（如 1080p↔4K）会改变桌面总宽。
    #   _layout_matches 只比 x/primary —— mutter 自动重排后期望 x 与实际 x 完全一致，
    #   看门狗会误判"布局没变"直接 return，导致触控矩阵残留旧值
    #   （症状：触控横向偏移 ~20%、大屏右缘触摸跳到第二块屏）。
    #   故矩阵重算必须独立于布局纠偏，永远先做；矩阵变了就立即刷 udev 规则+重枚举。
    _mtx, mtx_changed = write_matrix(geom)
    if _layout_matches(logical, cfg):
        if mtx_changed and '--no-touch' not in sys.argv:
            subprocess.call(['sudo', '-n', '/usr/local/sbin/touchscreen-map.sh'],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return
    if '--no-touch' not in sys.argv:
        subprocess.call(['sudo', '-n', '/usr/local/sbin/touchscreen-map.sh'],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for attempt in range(6):
        try:
            proxy.call_sync('ApplyMonitorsConfig',
                            GLib.Variant('(uua(iiduba(ssa{sv}))a{sv})',
                                         (serial, 1, cfg, {})),
                            Gio.DBusCallFlags.NONE, -1, None)
        except Exception as e:
            if 'stale' in str(e).lower():
                try:
                    serial, monitors, logical = get_state(proxy)
                    cfg, geom = build_config(monitors, logical)
                    if not cfg:
                        break
                except Exception:
                    pass
                continue
            sys.stderr.write("watch apply 失败: %s\n" % e)
            return
        try:
            _s, _m, _l = get_state(proxy)
            if _layout_matches(_l, cfg):
                print("watch: 已重新固定 HDMI-1 主屏与排列")
                return
        except Exception:
            pass
        time.sleep(2)
    print("watch: 警告 HDMI-1 主屏未能稳定")


def watch_mode():
    """常驻看门狗：先应用一次，再监听 MonitorsChanged 持续纠偏。"""
    # 单例：避免手动启动 + 自启动重复拉起多个看门狗
    try:
        import fcntl
        _lk = open('/run/user/%d/am60-layout-watchdog.lock' % os.getuid(), 'w')
        fcntl.flock(_lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except Exception as e:
        sys.stderr.write("watchdog 可能已在运行（锁失败）: %s\n" % e)
        sys.exit(0)
    proxy = get_proxy(wait=True)
    if '--no-force' not in sys.argv:
        ensure_main_ready()
        time.sleep(3)
        for _ in range(40):
            try:
                s, m, l = get_state(proxy)
            except Exception:
                break
            if any(x['connector'] == MAIN_CONNECTOR
                   and (x['current'] or x.get('allmodes')) for x in m):
                break
            time.sleep(1)
    apply_if_needed(proxy)

    def on_signal(*args):
        # Gio.DBusProxy 'g-signal': (proxy, sender, signal_name, path, iface, params)
        if len(args) >= 3 and args[2] == 'MonitorsChanged':
            apply_if_needed(proxy)

    proxy.connect('g-signal', on_signal)
    print("watch: 已启动，监听 MonitorsChanged 以持续固定 HDMI-1 主屏")
    GLib.MainLoop().run()


def main():
    if '--watch' in sys.argv:
        return watch_mode()
    proxy = get_proxy(wait=('--wait' in sys.argv))

    # 大屏口无 HPD：先强制 connected + 等待 EDID，确保 mutter 真正把它
    # 纳入配置（否则会按"旧/未就绪"状态把它排除，应用后大屏反而黑掉）。
    # 必须在 get_state() 之前做，否则抓到的还是大屏 disconnected 的旧状态。
    if '--no-force' not in sys.argv:
        ensure_main_ready()
        time.sleep(3)  # 等 mutter 完成重探测后的异步重配置，避免 serial 过期

    # ★ 轮询直到大屏 HDMI-A-1 真正进入 mutter 状态（connected + 有模式）。
    # ensure_main_ready 只把大屏拉到 KMS 层，mutter 枚举/提交有延迟；若此刻就
    # 算布局，大屏会被漏掉 → 主屏错位到 Type-C/前置 HDMI。最多等 40s。
    for _ in range(40):
        try:
            serial, monitors, logical = get_state(proxy)
        except Exception as e:
            sys.stderr.write("GetCurrentState 失败（会话总线未就绪？）: %s\n" % e)
            return 1
        if any(m['connector'] == MAIN_CONNECTOR and (m['current'] or m.get('allmodes'))
               for m in monitors):
            break
        time.sleep(1)

    if '--query' in sys.argv:
        print_state(serial, monitors, logical)
        return 0

    cfg, geom = build_config(monitors, logical)
    if not cfg:
        print("没有已启用的输出，跳过")
        return 0

    print("== 期望布局 ==")
    for c in cfg:
        print("  x=%-5d y=%d scale=%s primary=%-5s %s" %
              (c[0], c[1], c[2], c[4], c[5][0][0]))

    mtx, _changed = write_matrix(geom)
    print("触控矩阵 -> %s  (%s)" % (mtx, MATRIX_FILE))

    # 让 root 的 udev 规则用上新矩阵（sudoers 已给 NOPASSWD）
    if '--no-touch' not in sys.argv:
        rc = subprocess.call(['sudo', '-n', '/usr/local/sbin/touchscreen-map.sh'],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if rc != 0:
            sys.stderr.write("提示: touchscreen-map.sh 未以 root 执行 (rc=%d)，矩阵已记录但暂未生效\n" % rc)

    # 对比当前布局，判断是否真的需要改
    cur_x, cur_primary = {}, {}
    for lm in logical:
        for c in lm['monitors']:
            cur_x[c] = lm['x']
            cur_primary[c] = lm['is_primary']
    need = any(cur_x.get(c[5][0][0]) != c[0] or
               cur_primary.get(c[5][0][0]) != c[4] for c in cfg)

    if not need:
        # 仍强制提交一次：开机/热插拔时 mutter 可能“以为已配置”却未真正
        # 向 KMS 提交模式（大屏无信号）。去掉跳过逻辑，确保 HDMI-1 主屏
        # 真正落地。
        pass
    if '--dry-run' in sys.argv:
        print("(dry-run) 跳过应用")
        return 0

    # ★ 用 method=1(临时，不落盘)：热插拔/重启都靠本脚本重跑来固定 HDMI-1 主屏，
    # 不再把布局持久化进 ~/.config/monitors.xml。
    # 为什么不能 method=2：method=2 会把布局写入磁盘；插拔前置 HDMI / Type-C 时
    # mutter 拿【上一拓扑】的已存配置去套【新】拓扑，套不上就弹"保存显示设置"
    # （Could not apply stored configuration）。改成 1 后无已存配置可套，弹窗消失。
    # HDMI-1 主屏的三道保险：①内核 Plan B 补丁把 Type-C 排序最末，mutter 默认主屏即
    # HDMI-1；②udev 热插拔经 am60-relayout-user.sh 重跑本脚本；③登录自启动 .desktop
    # 也跑一次。故无需持久化即可稳定，且不再弹"保存显示设置"。
    for attempt in range(6):
        try:
            proxy.call_sync('ApplyMonitorsConfig',
                            GLib.Variant('(uua(iiduba(ssa{sv}))a{sv})',
                                         (serial, 1, cfg, {})),
                            Gio.DBusCallFlags.NONE, -1, None)
        except Exception as e:
            if 'stale' in str(e).lower():
                print("serial 过期，重新获取后重试 (%d)..." % (attempt + 1))
                try:
                    serial, monitors, logical = get_state(proxy)
                    cfg, geom = build_config(monitors, logical)
                    if not cfg:
                        break
                except Exception:
                    pass
                continue
            sys.stderr.write("ApplyMonitorsConfig 失败: %s\n" % e)
            return 1
        # 校验：HDMI-1 是否真成了主屏（在逻辑监视器里且 is_primary）
        try:
            _s, _m, _l = get_state(proxy)
            if any(lm['is_primary'] and MAIN_CONNECTOR in lm['monitors']
                   for lm in _l):
                print("已应用布局（HDMI-1 主屏已确认）")
                return 0
        except Exception:
            pass
        time.sleep(2)
    print("警告: 已多次尝试，HDMI-1 主屏未能稳定确认（请检查 DRM/EDID）")
    return 0


if __name__ == '__main__':
    sys.exit(main())
