# 批 17 加密原版备份恢复设备验收报告（2026-10-27）

> 说明：本报告**新建独立文件**（未追加到 `docs/DEVICE_ACCEPTANCE_20261027_16X.md`，该文件范围固定为批 8~16）。
> 范围：批 17（原版 `BackupAES` 加密 zip 备份的**探测 + 密码框 + 凭密码恢复**；Cookie / 运行变量落库；
> 自有单文件备份的敏感面排除）。设备：Windows 宿主 + MuMu「Test测试」实例。
> 结论：**场景 1~9 全部 PASS**，未发现功能性缺陷（FATAL EXCEPTION = 0，ANR = 0）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（实测在线；adbd 以 root 运行，设备自带 `sqlite3`） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15 / ABI `x86_64` |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 应用包名 | `io.legado.flutter_legado` |
| 安装版本 | **versionName 2.0.391 / versionCode 392**（`lastUpdateTime 2026-10-27 09:47:44`） |
| 源码基线 | `master` HEAD `8511e11021`（`docs: 登记批17d Cookie 恢复锁序与偏好密码口径`） |
| 验收时间 | 2026-10-27 09:43 ~ 10:00（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261027_backup_pwd/`（已在 `.gitignore` 的 `/tmp_*` 内，不入库） |

### 1.1 Rust Android 构建（`rust/scripts/build-android.ps1 -Mode release`）

退出码 **0**；三 ABI 产出并复制到 `flutter_legado/android/app/src/main/jniLibs/`。

| ABI | 大小 | mtime | quickjs |
|---|---|---|---|
| arm64-v8a | 50,258,160 B | 2026-10-27 09:41:53 | true |
| armeabi-v7a | 33,321,084 B | 2026-10-27 09:42:45 | **false（既有回退）** |
| x86_64 | 50,361,048 B | 2026-10-27 09:43:28 | true |

- 版本源指纹：`rustFingerprint = 6aad6c63cffb9dbee69edc85b9314ae296d7dd701d022892363777f01536340a`，FRB `contentHash = -951865050`。
- 证据：`logs/build_rust_android.log`、`logs/build_so.txt`。
- **构建侧已知项**：armv7 的 `rar` crate 编译失败（`E0277`）→ 脚本按既有逻辑回退「无 quickjs」，`.meta` 记为 `quickjs:false`；本设备为 x86_64，不影响本批结论（与 16X 验收记录一致）。

### 1.2 Flutter 发布包（`flutter build apk --release`）

| 项 | 值 |
|---|---|
| 退出码 | 0（`√ Built build\app\outputs\flutter-apk\app-release.apk (184.8MB)`） |
| 路径 | `flutter_legado/build/app/outputs/flutter-apk/app-release.apk` |
| 大小 | 193,728,596 B |
| sha256 | `8407aac59b459059c77fae6b4ebf2488475c5242c2a2c4af2d5304d92907e22e` |
| 安装 | `adb install -r` 成功（覆盖 2.0.391，数据保留） |

- 安装前后 DB 基线一致（见 §四 场景 1 前基线）：`servers 0 / cookies 218 / caches 56 / book_sources 534`。
- 证据：`logs/build_apk.log`、`logs/apk_build_and_preinstall.txt`、`logs/install.txt`、`db/baseline_before_install.txt`。

### 1.3 测试包构造（宿主 openssl + Python zipfile，**独立于我方代码**）

密钥口径：`MD5(password)` 小写十六进制串的**前 16 个 ASCII 字符**（不做 hex 解码）；AES-128-ECB/PKCS5（openssl 的 PKCS7 对 16 字节块等价）；Base64 单行。

```
空密码 key = d41d8cd98f00b204  -> -K 64343164386364393866303062323034
secret  key = 5ebe2294ecd0e0f0  -> -K 35656265323239346563643065306630

openssl enc -aes-128-ecb -K <keyhex> -nosalt -in plain/servers_accept.json -out ... -a -A
```

| 包 | 内容 | sha256 |
|---|---|---|
| A（空密码） | `servers.json`（空密码密钥加密，`[{"id":-1,"name":"验收DAV",...}]`）+ 明文 `bookSource.json`（验收书源） | `f03b18f1329a37211f351c3f153799192c3c105ec5277446759865e699204cba` |
| B（密码 `secret`） | `servers.json` + `cookies.json`（`example.com` / `sid=abc; theme=dark`）+ `runtimeSourceCache.json`（`sourceVariable_demo`=`v1`, deadline 0）均加密；明文 `bookSource.json` | `8f59ee227a658abdc239c4e41348e6acc6fdfc029844b9d144cd5a87ce4e5318` |
| C（损坏） | `servers.json` = secret 密文截断为前 40 个 Base64 字符 | `f439388ffc55b7f72f8e96589b7087c6301c45486b2db9d9eda17df3c2641662` |
| S9（原版真实包） | 原版 Legado 3.26082823 在设备内设置本地密码 `secret` 后真实备份出的 `backup.zip` | `f7ebf3ec3872356b90d056e6022bc168b24684da9a49f3a8c1a3cc7ce74c3e88` |

- 构造后已用 openssl 反向解密自检（`servers_A/B`、`cookies_B`、`runtime_B` 均还原为原明文；错误密钥报 `bad decrypt`）。
- 证据：`openssl_commands.log`、`logs/make_packages.log`、`plain/`、`packages/`、`logs/s9_real_servers_decrypt.txt`。
- 测试包推送 `/sdcard/Download/` 后由 `file_picker`（SAF）选择；验收结束已全部删除（§五 清理）。

## 二、场景结论总览

| # | 场景 | 结论 | 关键证据 |
|---|---|---|---|
| 1 | 包 A：探测不弹框，直接恢复成功 | **PASS** | `screens/22_S1_confirm.png`、`screens/23_S1_after_restore.png`（「恢复成功」）、`db/s1_after.txt` |
| 2 | 包 B：弹「输入备份密码」+ 三个受保护文件标签 + 空提交内联校验 | **PASS** | `screens/32_S2_password_dialog.png`、`screens/33_S2_empty_submit.png`、`db/s2_after_empty.txt` |
| 3 | 错误密码：内联「密码错误或备份已损坏，请重试」+ 零落库 | **PASS** | `screens/35_S3_wrong_password.png`、`db/s2_before.txt` vs `db/s3_after_wrong.txt` |
| 4 | 正确密码：servers/cookies/caches/书源全部恢复 | **PASS** | `screens/72_S4b_success_snack.png`、`db/s4_after_correct.txt`、`db/s4b_after_repeat.txt` |
| 5 | 取消密码框：零写入 | **PASS** | `screens/53_S5_after_cancel.png`、`db/s5_before.txt` vs `db/s5_after_cancel.txt` |
| 6 | 损坏包：明确错误、不崩溃 | **PASS** | `screens/63_S6_after_wrong.png`、`db/s6_after_corrupt.txt`（PID 存活） |
| 7 | 自有本地备份敏感面排除 | **PASS** | `backup_own_1793065958719.json`、`logs/s7_assertions.txt`、`screens/82_S7_backup_success.png` |
| 8 | 回归（关于页 / 阅读器 / 备份恢复页 / 日志） | **PASS** | `screens/91_S8_about.png`、`screens/92_S8_reader.png`、`logs/full_logcat_final.txt`（FATAL=0） |
| 9 | 原版真实加密备份包恢复（可选，已执行） | **PASS** | `packages/original_real_backup.zip`、`screens/134_S9_real_restore_success.png`、`logs/s9_real_servers_decrypt.txt` |

## 三、逐场景明细

### 场景 1：包 A 无密码直接恢复 —— PASS

**操作**：我的 → 设置 → 备份与恢复 → 长按「恢复」→ SAF 选 `backup_accept_A.zip` → 覆盖确认「恢复」。

**预期/实际**：
- 检查备份（`backupInspect`）判定 `passwordRequired=false`，**未出现密码框**，直接进入「恢复中…」并提示「恢复成功」。
- DB 变化（`db/s1_before.txt` → `db/s1_after.txt`）：

| 表 | 前 | 后 |
|---|---|---|
| servers | 0 | **1**（`-1 / 验收DAV / WEBDAV / {"url":"https://dav.example/"} / 1`） |
| book_sources | 534 | **535**（`验收书源`，`enabled=1`） |
| cookies | 218 | 218（包 A 无 cookies） |
| caches | 56 | 56 |

**证据**：`screens/22_S1_confirm.png`、`screens/23_S1_after_restore.png`、`db/s1_before.txt`、`db/s1_after.txt`、`logs/s1_logcat.txt`（SAF 选择记录，无密码框）。

### 场景 2：包 B 弹密码框 + 空提交校验 —— PASS

**实际**：
- 出现「输入备份密码」对话框，受保护文件标签完整且顺序固定：
  `· 服务器配置（servers.json）`、`· 登录信息（cookies.json）`、`· 书源运行变量（runtimeSourceCache.json）`。
- 不输入直接点「确定」：内联显示「请输入备份密码」，对话框不关闭、**未执行恢复**（`servers 1 / cookies 218 / caches 56 / book_sources 535` 与提交前完全一致）。
- 密码输入框默认掩码，带「显示密码」切换；未复用本机 `localPassword`。

**证据**：`screens/32_S2_password_dialog.png`、`screens/33_S2_empty_submit.png`、`db/s2_before.txt`、`db/s2_after_empty.txt`。

### 场景 3：错误密码零落库 —— PASS

**操作**：场景 2 对话框内输入 `wrong` → 确定。

**实际**：
- 进度框「恢复中…」短暂出现并关闭后，**同一密码框重开**，内联红字「密码错误或备份已损坏，请重试」，保留上次输入（掩码 5 位）便于修改。
- 恢复前后行数不变（`db/s2_before.txt` 与 `db/s3_after_wrong.txt` 均为 1/218/56/535），零落库。

**证据**：`screens/35_S3_wrong_password.png`、`db/s2_before.txt`、`db/s3_after_wrong.txt`。

### 场景 4：正确密码全量恢复 —— PASS

**操作**：同一密码框内改为 `secret` → 确定（另做一次重复恢复，捕获成功提示）。

**实际**：
- 提示「恢复成功」（`screens/72_S4b_success_snack.png`）；重复恢复幂等，行数不再增长。
- DB 校验（`db/s4_after_correct.txt`）：

| 断言 | 结果 |
|---|---|
| servers 出现 `验收DAV` | `-1 / 验收DAV / WEBDAV / {"url":"https://dav.example/"}` ✅ |
| cookies 恢复 | `example.com` → `sid=abc; theme=dark`（总数 218 → **219**）✅ |
| caches 恢复运行变量 | `sourceVariable_demo` → `v1`，`deadline=0`（总数 56 → **57**）✅ |
| 书源按明文恢复 | `验收书源`（https://accept.example.com）`enabled=1`，总数 535 ✅ |

**证据**：`screens/72_S4b_success_snack.png`、`db/s4_after_correct.txt`、`db/s4b_after_repeat.txt`。

### 场景 5：取消密码框零写入 —— PASS

**操作**：重新选包 B → 覆盖确认 → 密码框点「取消」。

**实际**：回到备份与恢复页，无提示、无异常；前后 DB 完全一致（`db/s5_before.txt` / `db/s5_after_cancel.txt` 均为 1/219/57/535，`example.com` cookie 内容不变）。

**证据**：`screens/53_S5_after_cancel.png`、`db/s5_before.txt`、`db/s5_after_cancel.txt`。

### 场景 6：损坏包明确错误、不崩溃 —— PASS

**操作**：选包 C（`servers.json` 为 secret 密文截断）→ 覆盖确认 → 密码框输入 `abc` → 确定。

**实际**：
- 损坏密文在探测阶段与合法密文不可区分（空密码解不开 → 判为需要密码），故先出现密码框；输入任意密码后得到明确错误「密码错误或备份已损坏，请重试」。
- 应用进程存活（`pidof` 前后均为同一 PID），无崩溃；DB 行数不变。
- 未出现静默「恢复成功」。

**证据**：`screens/62_S6_dialog.png`、`screens/63_S6_after_wrong.png`、`db/s6_after_corrupt.txt`。

### 场景 7：自有本地备份敏感面 —— PASS

**夹具**（因两个键在 UI 无独立入口）：应用停止后直写 `shared_prefs/FlutterSharedPreferences.xml`，注入
`localPassword=ACCEPT_LOCAL_PW_17`、`sync_webdav_password=ACCEPT_WEBDAV_PW_17`、
`remote_servers=[{id,name,url,username,password:"ACCEPT_REMOTE_PW_17"}]`（文件 owner/SELinux 标签保持不变），
重启应用后在备份与恢复页点「备份」，生成
`/storage/emulated/0/Download/legado/legado_backup_1793065958719.json`（4,290,334 B），pull 回宿主断言。

**断言结果**（`logs/s7_assertions.txt`，脚本 `check_backup_sensitive.py`）：
- 全文**不含** `ACCEPT_LOCAL_PW_17` / `ACCEPT_WEBDAV_PW_17` / `ACCEPT_REMOTE_PW_17`；
- `appPrefs` **不含** `localPassword` / `sync_webdav_password` 键；
- `appPrefs.remote_servers[0]` = `{"id":1,"name":"验收远程","url":"https://remote.example/","username":"u1"}`
  —— **无 `password` 字段**，非敏感字段保留（证明是值净化而非整键丢弃）。

**证据**：`screens/82_S7_backup_success.png`、`backup_own_1793065958719.json`、`logs/s7_assertions.txt`、`logs/prefs_seeded.xml`。

### 场景 8：回归 —— PASS

| 项 | 结果 | 证据 |
|---|---|---|
| 关于页版本 | 显示「版本 2.0.391」，与安装包一致 | `screens/91_S8_about.png` |
| 阅读器打开 | 书架打开《斗罗大陆》正常渲染正文与章节 | `screens/92_S8_reader.png` |
| 备份/恢复页 | 多次进出、长按菜单、备份、恢复均可用，无崩溃 | `screens/06_backup_page.png`、`screens/07_backup_scrolled.png` |
| 日志 | `FATAL EXCEPTION = 0`、`ANR = 0`（全量 11,900 行） | `logs/full_logcat_final.txt`、`logs/full_logcat_batch17.txt` |

### 场景 9（可选，已执行）：原版真实备份包 —— PASS

**操作**：
1. 启动原版 `com.legado.app.release` 3.26082823 → 我的 → 其它设置 → 「设置本地密码」输入 `secret`；
2. 备份与恢复 → 备份，产出 `/sdcard/Android/data/com.legado.app.release/files/backup.zip`（1,195,425 B，14 个条目）；
3. 复制为 `/sdcard/Download/backup_accept_real_original.zip`，在我方应用长按恢复 → 密码框仅列
   `· 服务器配置（servers.json）`（该包无 cookies/runtime）→ 输入 `secret` → 「恢复成功」。

**核对**：
- 原版真实 `servers.json`（24 B 密文）用 secret 密钥在宿主 openssl 解密得到 `[]`（`logs/s9_real_servers_decrypt.txt`）；
- 我方恢复成功（`screens/134_S9_real_restore_success.png`，另 `screens/132_S9b_t1.xml` 亦捕获到「恢复成功」）；
- 恢复后 `servers` 仍为 1、`cookies` 219、`caches` 57（该包 servers 为空数组 → 不清空本机既有 servers）；
- `book_sources` 535 不变：原版书源按 URL upsert（本机已有同 URL 行），QA 书源保留——符合当前恢复器「不删除本机独有书源」的实现口径。

**证据**：`packages/original_real_backup.zip`、`screens/127_S9_dialog.png`、`screens/134_S9_real_restore_success.png`、`db/s9_before.txt`、`db/s9b_after.txt`、`logs/s9_real_servers_decrypt.txt`。

## 四、DB 行数时间线（统一取证）

数据库：`/data/data/io.legado.flutter_legado/app_flutter/legado.db`（adbd root + 设备自带 sqlite3 直读；**未改装 debug 变体**）。

| 时点 | servers | cookies | caches | book_sources | 证据 |
|---|---|---|---|---|---|
| 安装新包前基线 | 0 | 218 | 56 | 534 | `db/baseline_before_install.txt` |
| 场景 1 前 | 0 | 218 | 56 | 534 | `db/s1_before.txt` |
| 场景 1 后（包 A） | 1 | 218 | 56 | 535 | `db/s1_after.txt` |
| 场景 2 前 | 1 | 218 | 56 | 535 | `db/s2_before.txt` |
| 空提交 / 错误密码 / 取消 后 | 1 | 218 | 56 | 535 | `db/s2_after_empty.txt`、`db/s3_after_wrong.txt`、`db/s5_after_cancel.txt` |
| 场景 4 后（包 B + secret） | 1 | 219 | 57 | 535 | `db/s4_after_correct.txt`、`db/s4b_after_repeat.txt` |
| 场景 6 后（包 C） | 1 | 219 | 57 | 535 | `db/s6_after_corrupt.txt` |
| 场景 9 前 / 后（原版真实包） | 1 / 1 | 219 / 219 | 57 / 57 | 535 / 535 | `db/s9_before.txt`、`db/s9_after.txt`、`db/s9b_after.txt` |
| 测试清理后 | 0 | 218 | 56 | 534 | `logs/cleanup.txt` |

## 五、验收后清理与设备状态

- 已删除 `/sdcard/Download/backup_accept_A/B/C.zip`、`backup_accept_real_original.zip`、本次生成的 `legado_backup_1793065958719.json`，以及 `/data/local/tmp/prefs_*.xml`。
- 已恢复测试夹具：`shared_prefs/FlutterSharedPreferences.xml` 还原为注入前快照（`logs/prefs_original.xml`，`ACCEPT_` 计数 0），应用重启后正常进入书架。
- 已删除注入的测试行：`servers(-1)`、`cookies(example.com)`、`caches(sourceVariable_demo)`、`book_sources(https://accept.example.com)`，DB 回到基线 0/218/56/534（`logs/cleanup.txt`）。
- `adb reverse --list` / `adb forward --list` 均为空（本批未使用 mock 服务与端口转发）。
- 应用最终状态：`2.0.391 / 392`，PID 正常，FATAL = 0（`screens/140_final_state.png`）。

## 六、观察项与遗留说明（均非缺陷）

1. **损坏包的探测口径**：截断/错密码的 `servers.json` 与合法密文在探测阶段不可区分（判定规则为「空密码能否解开」），因此用户会先看到密码框，输入后得到「密码错误或备份已损坏，请重试」。错误提示准确、无崩溃、零落库；若产品希望「损坏包不弹密码框直接报损坏」，需要新的探测启发式（例如 Base64 结构/块长度校验），属体验优化项。
2. **场景 9 的真实包覆盖面**：原版应用在本机数据为空，真实包不含 `cookies.json`/`runtimeSourceCache.json`，`servers.json` 解密为 `[]`。因此真实包验证的是「原版 `BackupAES` 密文与整体恢复链路」，非空 servers/cookies/runtime 的内容验证由 openssl 等价包 B 覆盖。若需真实非空包，需先在原版应用内产生持久 Cookie/服务器条目。
3. **原版真实包恢复的副作用（预期内）**：按当前恢复口径，书源为 upsert（不删除本机独有书源）、`bookGroup.json` 会写入分组（书架分组 Tab 变化）；15 本书与阅读进度未丢失。
4. **armv7 quickjs**：与 16X 相同的既有回退（`rar` 编译失败），本机 x86_64 不受影响；如需 armv7 完整引擎需单独修复该依赖。
5. 本批未发现需要回修的加密/密码/零落库缺陷。

编写者：QA 子代理（设备验收）｜ 2026-10-27
