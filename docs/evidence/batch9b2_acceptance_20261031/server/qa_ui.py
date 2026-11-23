# -*- coding: utf-8 -*-
# QA UI helper: adb uiautomator / tap / input / screenshot for batch9b2
import os, re, subprocess, sys, time
import xml.etree.ElementTree as ET

ADB = r'D:/Program Files/MuMuPlayer/nx_main/adb.exe'
SERIAL = '192.168.100.62:5555'
BASE = r'D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261031_batch9b2'
UI_XML = os.path.join(BASE, 'data', 'ui_current.xml')
SHOTS = os.path.join(BASE, 'shots')


def adb(*args, check=True):
    p = subprocess.run([ADB, '-s', SERIAL, *args], capture_output=True, text=True, encoding='utf-8', errors='replace')
    if check and p.returncode != 0:
        print('ADB_ERR', args, p.stdout, p.stderr)
    return p


def dump(name=None):
    adb('shell', 'uiautomator', 'dump', '/sdcard/qa9b2_ui.xml')
    adb('pull', '/sdcard/qa9b2_ui.xml', UI_XML)
    if name:
        dst = os.path.join(BASE, 'data', f'ui_{name}.xml')
        adb('pull', '/sdcard/qa9b2_ui.xml', dst)
    nodes = []
    for n in ET.parse(UI_XML).iter('node'):
        txt = n.get('text', '')
        desc = n.get('content-desc', '')
        cls = n.get('class', '')
        b = n.get('bounds', '')
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        x = y = 0
        if m:
            x = (int(m.group(1)) + int(m.group(3))) // 2
            y = (int(m.group(2)) + int(m.group(4))) // 2
        nodes.append({'text': txt, 'desc': desc, 'cls': cls, 'bounds': b, 'x': x, 'y': y})
    return nodes


def show(nodes=None):
    nodes = nodes if nodes is not None else dump()
    for n in nodes:
        if n['text'] or n['desc']:
            print(f"{n['text'][:70]!r}\t{n['desc'][:40]!r}\t{n['cls']}\t{n['bounds']}\t({n['x']},{n['y']})")


def find(nodes, needle, field='text', exact=False):
    cands = []
    for n in nodes:
        v = n[field]
        if (v == needle) if exact else (needle in v):
            cands.append(n)
    return cands


def tap_xy(x, y):
    adb('shell', 'input', 'tap', str(x), str(y))


def tap_text(needle, exact=False, field='text', dump_first=True, wait=1.2, index=0):
    nodes = dump() if dump_first else None
    c = find(nodes, needle, field=field, exact=exact)
    if not c:
        print('NOT_FOUND', needle)
        show(nodes)
        return False
    n = c[min(index, len(c) - 1)]
    tap_xy(n['x'], n['y'])
    time.sleep(wait)
    return True


def input_text(s):
    adb('shell', 'input', 'text', s)
    time.sleep(0.4)


def key(code):
    adb('shell', 'input', 'keyevent', str(code))
    time.sleep(0.5)


def shot(name):
    p = subprocess.run([ADB, '-s', SERIAL, 'exec-out', 'screencap', '-p'], capture_output=True)
    with open(os.path.join(SHOTS, name), 'wb') as f:
        f.write(p.stdout)
    print('SHOT', name, len(p.stdout))


def longpress_text(needle, exact=False, wait=1.5):
    nodes = dump()
    c = find(nodes, needle, exact=exact)
    if not c:
        print('NOT_FOUND', needle)
        show(nodes)
        return False
    n = c[0]
    adb('shell', 'input', 'swipe', str(n['x']), str(n['y']), str(n['x']), str(n['y']), '1200')
    time.sleep(wait)
    return True


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'dump'
    if cmd == 'dump':
        show(dump(sys.argv[2] if len(sys.argv) > 2 else None))
    elif cmd == 'tap':
        if len(sys.argv) > 3:
            tap_xy(int(sys.argv[2]), int(sys.argv[3]))
        else:
            tap_text(sys.argv[2])
    elif cmd == 'tap-exact':
        tap_text(sys.argv[2], exact=True)
    elif cmd == 'tap-desc':
        tap_text(sys.argv[2], field='desc')
    elif cmd == 'long':
        longpress_text(sys.argv[2])
    elif cmd == 'text':
        input_text(sys.argv[2])
    elif cmd == 'key':
        key(sys.argv[2])
    elif cmd == 'shot':
        shot(sys.argv[2])
    elif cmd == 'wait':
        time.sleep(float(sys.argv[2]))
