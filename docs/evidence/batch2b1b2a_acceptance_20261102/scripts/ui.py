"""Small adb/uiautomator helper for batch 2b-1b-2a device acceptance.

Usage:
  python ui.py dump
  python ui.py find "<text>"
  python ui.py tap "<text|desc substring>"
  python ui.py tapxy X Y
  python ui.py scroll "<text>" [max]
  python ui.py shot NAME
  python ui.py swipe x1 y1 x2 y2 [ms]
Always uses ASCII arguments only for commands; Chinese text must be passed as
UTF-8 (Git Bash on Windows handles this).
"""
import json
import os
import re
import subprocess
import sys
import time

ADB = r'D:/Program Files/MuMuPlayer/nx_main/adb.exe'
DEV = '192.168.100.62:5555'
ROOT = r'D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261102_batch2b1b2a'
OUT = os.path.join(ROOT, 'data')
SHOTS = r'D:/OH-WorkSpace/LegadoTeam/legado/docs/materials_1102'


def sh(*args, timeout=90):
    env = dict(os.environ)
    env['MSYS_NO_PATHCONV'] = '1'
    return subprocess.run([ADB, '-s', DEV, *args], capture_output=True,
                          text=True, encoding='utf-8', errors='replace',
                          timeout=timeout, env=env)


def dump():
    sh('shell', 'uiautomator', 'dump', '/sdcard/ui.xml')
    sh('pull', '/sdcard/ui.xml', os.path.join(OUT, 'ui.xml'))
    try:
        return open(os.path.join(OUT, 'ui.xml'), encoding='utf-8',
                    errors='replace').read()
    except OSError:
        return ''


def nodes(xml):
    for m in re.finditer(r'<node [^>]*>', xml):
        t = m.group(0)

        def g(k):
            mm = re.search(k + r'="([^"]*)"', t)
            return mm.group(1) if mm else ''
        yield dict(text=g('text'), desc=g('content-desc'),
                   bounds=g('bounds'), cls=g('class'), click=g('clickable'))


def parse_bounds(b):
    m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
    if not m:
        return None
    return tuple(int(x) for x in m.groups())


def find(xml, target):
    for n in nodes(xml):
        if target in n['text'] or target in n['desc']:
            return n
    return None


def tap_node(n):
    b = parse_bounds(n['bounds'])
    x = (b[0] + b[2]) // 2
    y = (b[1] + b[3]) // 2
    sh('shell', 'input', 'tap', str(x), str(y))
    return x, y


def show(xml):
    for n in nodes(xml):
        if n['text'] or n['desc']:
            print(n['bounds'], n['cls'].split('.')[-1],
                  'click=' + n['click'],
                  'text=' + repr(n['text']), 'desc=' + repr(n['desc']))


def main():
    cmd = sys.argv[1]
    if cmd == 'dump':
        show(dump())
    elif cmd == 'find':
        n = find(dump(), sys.argv[2])
        print(json.dumps(n, ensure_ascii=False) if n else 'NOT FOUND')
    elif cmd == 'tap':
        target = sys.argv[2]
        for i in range(10):
            n = find(dump(), target)
            if n:
                print('TAP', target, tap_node(n))
                return 0
            time.sleep(0.6)
        print('NOT FOUND', target)
        return 1
    elif cmd == 'tapxy':
        sh('shell', 'input', 'tap', sys.argv[2], sys.argv[3])
        print('TAPPED', sys.argv[2], sys.argv[3])
    elif cmd == 'scroll':
        target = sys.argv[2]
        max_n = int(sys.argv[3]) if len(sys.argv) > 3 else 15
        for _ in range(max_n):
            n = find(dump(), target)
            if n:
                print('FOUND', n['bounds'], n['desc'][:80] or n['text'][:80])
                return 0
            sh('shell', 'input', 'swipe', '540', '1500', '540', '500', '250')
            time.sleep(0.6)
        print('NOT FOUND', target)
        return 1
    elif cmd == 'shot':
        name = sys.argv[2]
        os.makedirs(SHOTS, exist_ok=True)
        p = os.path.join(SHOTS, name + '.png')
        with open(p, 'wb') as f:
            f.write(sh('exec-out', 'screencap', '-p').stdout.encode('latin-1')
                    if False else b'')
        # binary-safe capture
        env = dict(os.environ)
        env['MSYS_NO_PATHCONV'] = '1'
        r = subprocess.run([ADB, '-s', DEV, 'exec-out', 'screencap', '-p'],
                           capture_output=True, timeout=90, env=env)
        with open(p, 'wb') as f:
            f.write(r.stdout)
        print(p, os.path.getsize(p))
    elif cmd == 'swipe':
        vals = sys.argv[2:6]
        ms = sys.argv[6] if len(sys.argv) > 6 else '300'
        sh('shell', 'input', 'swipe', *vals, ms)
        print('SWIPED', *vals)
    else:
        print('unknown')
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
