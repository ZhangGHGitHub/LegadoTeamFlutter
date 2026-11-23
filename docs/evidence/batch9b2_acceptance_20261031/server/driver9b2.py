# -*- coding: utf-8 -*-
# 批9b-2 设备驱动辅助：滚动查找 / 点击 / 导航 / 截图 / DB 查询
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import qa_ui as ui  # noqa: E402

ADB = ui.ADB
SERIAL = ui.SERIAL
BASE = ui.BASE


def nodes():
    return ui.dump()


def find(nodes_, needle, field='desc', exact=False):
    out = []
    for n in nodes_:
        v = n[field]
        if (v == needle) if exact else (needle in v):
            out.append(n)
    return out


def tap(n):
    ui.tap_xy(n['x'], n['y'])


def scroll(direction='down', dist=400):
    if direction == 'down':
        ui.adb('shell', 'input', 'swipe', '540', '1600', '540', str(1600 - dist), '800')
    else:
        ui.adb('shell', 'input', 'swipe', '540', '400', '540', str(400 + dist), '800')
    time.sleep(0.5)


def scroll_find(needle, field='desc', direction='down', max_steps=12):
    for i in range(max_steps):
        ns = nodes()
        c = find(ns, needle, field=field)
        if c:
            return c[0], ns
        scroll(direction)
    return None, nodes()


def shot(name):
    ui.shot(name)


def db_query(sql):
    p = subprocess.run(
        [ADB, '-s', SERIAL, 'shell',
         f'sqlite3 /data/user/0/io.legado.flutter_legado/app_flutter/legado.db "{sql}"'],
        capture_output=True, text=True, encoding='utf-8', errors='replace')
    return p.stdout.strip()


def db_exec(sql):
    return db_query(sql)


def prefs():
    p = subprocess.run(
        [ADB, '-s', SERIAL, 'shell',
         'cat /data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml'],
        capture_output=True, text=True, encoding='utf-8', errors='replace')
    return p.stdout


def goto_settings():
    """从任意页面回主界面 → 我的 → 设置（外观/高级）"""
    # 连续 BACK 直到出现底部 Tab
    for _ in range(5):
        ns = nodes()
        if find(ns, 'Home', field='desc') or find(ns, '书架', field='desc'):
            break
        ui.adb('shell', 'input', 'keyevent', '4')
        time.sleep(0.8)
    c = find(nodes(), '我的', field='desc')
    if c:
        tap(c[0])
        time.sleep(1)
    n, ns = scroll_find('设置\n外观', field='desc', direction='down', max_steps=10)
    if not n:
        # 可能已滚动到底后设置在上方
        n, ns = scroll_find('设置\n外观', field='desc', direction='up', max_steps=10)
    if n:
        tap(n)
        time.sleep(1)
        return True
    return False


def goto_other_settings():
    if not goto_settings():
        print('SETTINGS_NOT_FOUND')
        ui.show(nodes())
        return False
    n = find(nodes(), '高级\n功能相关', field='desc')
    if not n:
        n = find(nodes(), '高级', field='desc')
    if not n:
        print('ADVANCED_NOT_FOUND')
        ui.show(nodes())
        return False
    tap(n[0])
    time.sleep(1)
    return True


def goto_thread_row():
    if not goto_other_settings():
        return None
    n, ns = scroll_find('更新和搜索线程数', field='desc', direction='down', max_steps=14)
    if not n:
        n, ns = scroll_find('更新和搜索线程数', field='desc', direction='up', max_steps=14)
    return n


def set_thread_count(value):
    """在已定位线程行处打开对话框并输入数字，确认"""
    n = find(nodes(), '更新和搜索线程数', field='desc')
    if not n:
        print('THREAD_ROW_NOT_VISIBLE')
        return False
    tap(n[0])
    time.sleep(1)
    ns = nodes()
    ed = [x for x in ns if x['cls'] == 'android.widget.EditText']
    if not ed:
        print('NO_EDIT')
        ui.show(ns)
        return False
    tap(ed[0])
    time.sleep(0.3)
    ui.adb('shell', 'input', 'keyevent', '123')
    for _ in range(6):
        ui.adb('shell', 'input', 'keyevent', '67')
    ui.adb('shell', 'input', 'text', str(value))
    time.sleep(0.4)
    ns = nodes()
    confirm = find(ns, '确定', field='desc', exact=True)
    if not confirm:
        print('NO_CONFIRM')
        ui.show(ns)
        return False
    tap(confirm[0])
    time.sleep(1.2)
    return True


def open_cache_page():
    """主界面 → 我的 → 设置 → 缓存管理（离线缓存页）"""
    # 先回到底部 Tab 可见的主界面
    for _ in range(6):
        ns = nodes()
        if find(ns, 'Home', field='desc') or find(ns, '书架', field='desc'):
            break
        ui.adb('shell', 'input', 'keyevent', '4')
        time.sleep(0.6)
    if not open_mine():
        return False
    n, _ = scroll_find('设置\n外观', field='desc', direction='down', max_steps=10)
    if not n:
        n, _ = scroll_find('设置\n外观', field='desc', direction='up', max_steps=10)
    if not n:
        return False
    tap(n)
    time.sleep(1)
    c = find(nodes(), '缓存管理', field='desc')
    if not c:
        return False
    tap(c[0])
    time.sleep(2)
    return True


def stop_buttons():
    return [x for x in nodes() if x['desc'] == '停止下载']


def open_mine():
    for _ in range(4):
        ns = nodes()
        c = find(ns, '我的', field='desc')
        if c:
            tap(c[0])
            time.sleep(1)
            return True
        ui.adb('shell', 'input', 'keyevent', '4')
        time.sleep(0.8)
    return False
