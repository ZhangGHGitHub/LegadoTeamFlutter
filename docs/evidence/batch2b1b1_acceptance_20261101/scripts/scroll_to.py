"""Scroll the appearance page until a target text is visible; print its bounds.

Usage: python scroll_to.py "<text>" [max_swipes]
Saves ui dumps via adb; uses uiautomator bounds.
"""
import re
import subprocess
import sys
import time

ADB = r'D:/Program Files/MuMuPlayer/nx_main/adb.exe'
DEV = '192.168.100.62:5555'
TMP = r'D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261101_batch2b1b1/data/ui.xml'


def sh(*args, timeout=60):
    return subprocess.run([ADB, '-s', DEV, *args], capture_output=True, text=True, timeout=timeout)


def dump():
    sh('shell', 'uiautomator', 'dump', '/sdcard/ui.xml')
    sh('pull', '/sdcard/ui.xml', TMP)
    try:
        return open(TMP, encoding='utf-8', errors='replace').read()
    except OSError:
        return ''


def nodes(xml):
    for m in re.finditer(r'<node [^>]*>', xml):
        t = m.group(0)
        def g(k):
            mm = re.search(k + r'="([^"]*)"', t)
            return mm.group(1) if mm else ''
        yield dict(text=g('text'), desc=g('content-desc'), bounds=g('bounds'), cls=g('class'), click=g('clickable'))


def find(xml, target):
    for n in nodes(xml):
        if target in n['text'] or target in n['desc']:
            return n
    return None


def main():
    target = sys.argv[1]
    max_swipes = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    direction = 'down'  # content moves up => scroll down page
    for i in range(max_swipes):
        xml = dump()
        n = find(xml, target)
        if n:
            print('FOUND', n['bounds'], '|', n['desc'][:60] or n['text'][:60])
            return 0
        before = len(xml)
        if direction == 'down':
            sh('shell', 'input', 'swipe', '540', '1500', '540', '500', '200')
        else:
            sh('shell', 'input', 'swipe', '540', '500', '540', '1500', '200')
        time.sleep(0.7)
        xml2 = dump()
        if len(xml2) == before and find(xml2, target) is None:
            # hit the end; reverse once
            direction = 'up' if direction == 'down' else 'down'
    print('NOT FOUND', target)
    return 1


if __name__ == '__main__':
    sys.exit(main())
