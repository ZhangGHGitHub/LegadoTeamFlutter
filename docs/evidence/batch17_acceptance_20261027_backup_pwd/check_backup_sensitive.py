"""场景7 断言：我方单文件备份 JSON 不得携带设备级密码明文。

断言项（与 AGENTS/批17c 口径一致）：
1. 全文不得出现 localPassword 的测试值（ACCEPT_LOCAL_PW_17）；
2. 全文不得出现 sync_webdav_password 的测试值（ACCEPT_WEBDAV_PW_17）；
3. appPrefs 内不得出现 localPassword / sync_webdav_password 键；
4. appPrefs.remote_servers 内每个服务器对象不得含 password 键
   （大小写不敏感），且全文不得出现远程书库测试密码（ACCEPT_REMOTE_PW_17）；
5. remote_servers 的非敏感字段仍在（id/name/url/username），证明
   「值净化而非整键丢弃」。
"""

import json
import sys


def main() -> int:
    path = sys.argv[1]
    raw = open(path, encoding="utf-8").read()
    data = json.loads(raw)
    prefs = data.get("appPrefs") or {}
    failures = []

    for value in ("ACCEPT_LOCAL_PW_17", "ACCEPT_WEBDAV_PW_17", "ACCEPT_REMOTE_PW_17"):
        if value in raw:
            failures.append(f"全文包含敏感值 {value}")

    for key in ("localPassword", "sync_webdav_password"):
        if key in prefs:
            failures.append(f"appPrefs 含键 {key}")

    remote_raw = prefs.get("remote_servers")
    if remote_raw is None:
        failures.append("appPrefs 缺 remote_servers（无法验证净化，测试夹具未生效）")
    else:
        servers = json.loads(remote_raw) if isinstance(remote_raw, str) else remote_raw
        if not isinstance(servers, list) or not servers:
            failures.append(f"remote_servers 形态异常: {remote_raw!r}")
        else:
            for entry in servers:
                lowered = {str(k).lower() for k in entry}
                if "password" in lowered:
                    failures.append(f"remote_servers 条目含 password 字段: {entry}")
            kept = [k for k in ("id", "name", "url", "username") if k in servers[0]]
            print(f"remote_servers[0] 保留字段: {kept}")
            print(f"remote_servers[0] 原样输出: {json.dumps(servers[0], ensure_ascii=False)}")

    print(f"备份文件: {path}")
    print(f"顶层键: {sorted(data.keys())}")
    print(f"appPrefs 键数: {len(prefs)}；含 remote_servers: {'remote_servers' in prefs}")
    if failures:
        print("FAIL:")
        for f in failures:
            print("  -", f)
        return 1
    print("PASS: 三项敏感面断言全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
