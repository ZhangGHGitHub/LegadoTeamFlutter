# -*- coding: utf-8 -*-
"""批29 场景 A：并发搜索时序观测。

在搜索触发后按 ~1s 间隔 dump UI，记录「QA29 快源书 / QA29 慢源书」首次出现时刻，
并在 2s / 6s / 12s 时抓图。输出时间线到 stdout（可重定向为证据）。
"""
import time

import uihelper

FAST = "QA29 快源书"
SLOW = "QA29 慢源书"


def main():
    t0 = time.time()
    first_fast = None
    first_slow = None
    shots = {2.0: None, 6.0: None, 12.0: None}
    deadline = t0 + 26
    while time.time() < deadline:
        elapsed = time.time() - t0
        try:
            xml = uihelper.dump_xml()
        except Exception as e:  # dump 偶发失败不终止观测
            print("%6.2fs dump-error %s" % (elapsed, e), flush=True)
            time.sleep(0.3)
            continue
        now = time.time() - t0
        has_fast = FAST in xml
        has_slow = SLOW in xml
        if has_fast and first_fast is None:
            first_fast = now
        if has_slow and first_slow is None:
            first_slow = now
        print("%6.2fs fast=%s slow=%s" % (now, has_fast, has_slow), flush=True)
        for mark in shots:
            if shots[mark] is None and now >= mark:
                uihelper.cmd_shot(["qa29_A_%02ds.png" % int(mark)])
                shots[mark] = now
        if first_fast is not None and first_slow is not None:
            break
        time.sleep(0.4)
    print("RESULT first_fast=%s first_slow=%s"
          % ("%.2fs" % first_fast if first_fast is not None else "NOT_SEEN",
             "%.2fs" % first_slow if first_slow is not None else "NOT_SEEN"))


if __name__ == "__main__":
    main()
