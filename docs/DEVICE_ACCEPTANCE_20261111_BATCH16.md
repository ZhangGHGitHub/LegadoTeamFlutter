# 批16 正文行内图片混排渲染 — 设备验收报告

验收日期：2026-11-11
验收类型：MuMu 测试机真机运行时验收（只做验证与取证，未修改任何仓库代码）
证据目录：`docs/materials_1111a/`
验收依据：`docs/REFACTORING_ACTIVE_PLAN.md:1235`（批16 启动登记：正文分 text/image run、变高行、尺寸预测量、大图独立行/小图行内、失败占位、`readConfig.imageStyle`；设备判据「真实混排源/本地含图 HTML、翻页不丢字、FATAL/ANR/overflow=0」）

## 一、验收环境

| 项目 | 值 |
| --- | --- |
| 设备 | MuMu 模拟器，`192.168.100.62:5555`，`adb devices` 状态 `device` |
| 机型 / 系统 | `ro.product.model=SM-G9900`（MuMu 模拟），Android 15（API 35） |
| 分辨率 / 密度 / 逻辑宽度 | 1080x1920，480dpi → **360dp 宽** |
| 系统字体缩放 | `font_scale=1.0` |
| 被测包 | `io.legado.flutter_legado`（另一包 `com.legado.app.release` 为原版 3.26082823，未参与本批） |
| 设备路径 / APK sha256 | `/data/app/~~lW6n-db8jmmQp3YItW7Fhg==/io.legado.flutter_legado-e0vwfZ1XoQMQb9eqjEbtNQ==/base.apk`，设备内 `sha256sum` 实测 `b531ed022169bd4e04c06e28094b87570edf66613360fd57b4f34d42b78484a7`（与任务给定值一致） |
| 设备实测版本（dumpsys） | `versionName=2.0.485`，`versionCode=486`，`lastUpdateTime=2026-11-11 02:31:46` |
| 声明目标版本 | `2.0.485+486`（`flutter_legado/pubspec.yaml:4`），提交 `2795e47e65`（批16 收尾）——与设备一致，无版本漂移 |
| 宿主图片服务 | `python -m http.server 8091 --bind 192.168.100.52`，目录含 `big.png`（800x600）、`small.png`（40x40）、`x.png`（300x200，仅用于 file:// 用例） |
| 设备→宿主网络 | guest `wlan0=192.168.100.62/24`，与宿主 `192.168.100.52` 同网段；设备侧请求实测见 §5.7 |
| 测试书 1 | `tmp_qb16_book.txt`，7,757 B，UTF-8；`adb push` 到 `/sdcard/Download/` 后经书架「更多 → 添加本地」导入；应用内 10 章 |
| 测试书 2（对照） | `tmp_qb16_book2.txt`，3,007 B，同流程导入；应用内 4 章，用于「同构造不同文本」对照 |

准备说明：本轮通过**本地 TXT 正文内写 HTML `<img>`** 构造混排内容，实测净化链路**保留了 `<img>`**（大图/小图均被识别并渲染），因此未回退到在线书源或 EPUB。TXT 目录规则把「第X章结束标记。」也识别为章节，故测试书 1 被切成 10 章（测试素材产物，非缺陷）。

## 二、总体结论

| 结果 | 数量 |
| --- | --- |
| PASS | 8 |
| FAIL | 2 |
| BLOCKED | 0 |
| 合计 | 10 |

结论：批16 的**图片渲染主链路已实机跑通**——本地 TXT 的 `<img>` 未被剥离；800x600 大图按内容宽度自适应、独占变高行，前后文字均可见；40x40 小图与文字同行；失效地址显示占位而非崩溃；`file:///data/local/tmp/x.png`（文件真实存在且可读）被拒绝显示；纯文本章节在字号 20/24 下排版完整；两份 logcat 的五项崩溃计数与 `OutOfMemory` 均为 0；`pm clear` 后回到桌面。

但**文本完整性验收不通过**：含图片的章节中，翻页后非首页段落的**首行前缀字符不可见**（首行被按极小宽度断行 / 零高度行），同一版本、同一导入流程下纯文本章节与对照书 2 未复现。该现象直接违反本批设备判据「翻页不丢字」，故 C4、C5 判 FAIL（详见 §5.3 与 §6 P1）。

## 三、逐项结果

| 项 | 结果 | 证据文件（`docs/materials_1111a/`） | 说明 |
| --- | --- | --- | --- |
| A1 大图显示为图片、宽度自适应、独立成行 | PASS | `tmp_qb16_06_ch1_open.png`、`tmp_qb16_12_ch1_reopen_p1.png`、`http_8091_b16.log`（02:34:31 `GET /big.png 200`） | 章节「第一章 大图混排」首屏：标题文字下方为 800x600 蓝色大图（满内容宽 958/1080px，左右边距对称），不显示 `<img ...>` 文本，图片独立占变高行；设备侧真实发起 HTTP 取图 |
| A2 图片前后文字完整、无丢字 | PASS | `tmp_qb16_06_ch1_open.png` | 图片上一行「前文字。」、下一行「后文字。」均在首屏可见，无截断。注意：该项只覆盖图片紧邻的前后文字；**后续段落翻页存在丢字，见 C4** |
| B3 小图（40x40）行内显示 | PASS | `tmp_qb16_20_ch2_small_inline.png`、`tmp_qb16_30_ch2_font24_page1.png` | 「第二章 小图行内」首行渲染为「行首文字：■小图之后的文字」，红色 40x40 小图与前后文字**同一行**，未独占整行；字号 24 下同样保持行内。小图章后续段落存在首行丢字，记入 C4 |
| C4 前后翻页无丢字/无空白页/无溢出 | **FAIL** | `tmp_qb16_07_ch1_page2.png`、`tmp_qb16_13_ch1_reopen_p2.png`、`tmp_qb16_21_ch2_page2.png`、`tmp_qb16_31_ch3_missing_p2.png`、`tmp_qb16_34_cold_ch1_p2.png`、`tmp_qb16_20_ch2_small_inline.png`、`tmp_qb16_28_ch3_missing_p1.png` | 详见 §5.3：含图章节第 2 页起，多个段落首行前缀字符不可见（如「第一大段第2句：」显示为「2句：」），跨章、跨字号、冷启动后均复现；同时含图章节首页只放下首段、约 60% 页面空白（页面利用率异常）。无 FATAL/ANR/overflow 日志 |
| C5 改字号后图片与文字重排正常、不重叠 | **FAIL** | `tmp_qb16_22_reader_settings.png`（字号 20）、`tmp_qb16_23_font24_panel.png`、`tmp_qb16_25_ch2_font24_p1.png`、`tmp_qb16_26_ch2_font24_p2.png`、`tmp_qb16_30_ch2_font24_page1.png`、`tmp_qb16_27_ch5_font24_p1.png` | 字号 20→24 后图片随文字重排、**未发现文字与图片重叠**；但首行丢字缺陷在字号 24 下仍复现且形态变化（第二章 page2：第 3 段缺「小图」、第 4 段缺「小图章补」；page3 仅剩 3 行尾段），故判 FAIL |
| D6 图片不可达时显示占位、不崩溃、不破坏后续排版 | PASS | `tmp_qb16_28_ch3_missing_p1.png`、`tmp_qb16_31_ch3_missing_p2.png`、`http_8091_b16.log`（`GET /missing.png 404`） | 「第三章 失效占位」：缺失地址渲染为灰底 + 破损图片图标的**占位块**（占变高行），「占位前文字。」「占位后文字。」完整，无崩溃；第 2 页后续段落可读（其首行丢字属 §6 P1，与占位逻辑无关） |
| E7 `file://` 本地图片被拒绝、不崩溃 | PASS | `tmp_qb16_29_ch4_file_local.png`、`http_8091_b16.log` | 设备内 `/data/local/tmp/x.png`（1,639 B，`ls -l` 实测存在）被正文 `file:///data/local/tmp/x.png` 引用：页面显示占位而**未显示该本地图**，「安全前文字。」「安全后文字。」完整，无崩溃。宿主 HTTP 日志无该图请求（file 协议本就不经 HTTP），与拒绝行为一致 |
| F8 纯文本章节排版与升级前一致 | PASS | `tmp_qb16_10_ch5_plaintext.png`、`tmp_qb16_11_ch5_page2.png`（字号 20）、`tmp_qb16_27_ch5_font24_p1.png`（字号 24） | 「第五章 纯文本回归」：段落首行缩进 2 字、行距/段距正常、每页 2–3 段；字号 20 与 24 下段落首行均完整，未见本批丢字缺陷（主观比对旧版观感一致） |
| G9 logcat 五项崩溃计数 + OOM | PASS | `logcat_b16_session.txt`（5,016 行，全时段）、`logcat_b16.txt`（571 行，清空后冷启动→章节 1 翻页干净段） | 两份日志均为：`FATAL EXCEPTION`=0、`ANR in`=0、`E/flutter`=0、`overflowed`=0、`E AndroidRuntime`=0；`OutOfMemory`=0 |
| G10 清理与终态 | PASS | `tmp_qb16_35_terminal.png` | `pm clear io.legado.flutter_legado` 返回 `Success`；`pidof` 无输出；`mCurrentFocus=com.microsoft.launcher/.Launcher`；`font_scale=1.0`；截图显示桌面；宿主 HTTP 服务已停止（后台任务终止） |

## 四、测试素材与构造

**测试书 1（`tmp_qb16_book.txt`，10 章）**

| 章（应用内） | 正文关键内容 | 用途 |
| --- | --- | --- |
| 1 第一章 大图混排 | `前文字。<img src="http://192.168.100.52:8091/big.png">后文字。` + 6 段「第一大段第N句…」+ 8 段「第二大段第N句…」 | A1/A2/C4/C5 |
| 3 第二章 小图行内 | `行首文字：<img src="http://192.168.100.52:8091/small.png">小图之后的文字…` + 4 段「小图章补充段落N」 | B3/C4/C5 |
| 5 第三章 失效占位 | `占位前文字。<img src="http://192.168.100.52:8091/missing.png">占位后文字。` + 4 段 | D6 |
| 7 第四章 本地文件拒绝 | `安全前文字。<img src="file:///data/local/tmp/x.png">安全后文字。` + 4 段 | E7 |
| 9 第五章 纯文本回归 | 14 段纯文本「回归对照第N段…」，无任何标签 | F8（对照组） |

**测试书 2（`tmp_qb16_book2.txt`，4 章，对照）**：章 1 同样含 800x600 大图 + 10 段无 ASCII 数字的段落（「甲/乙/丙…段标记：一二三…」）；章 2 为纯文本。用于区分「图片导致」与「文本度量为触发条件」两种情况（结果见 §5.3 末）。

**构造/操作命令（可复现）**

```
export PATH="$PATH:/d/Program Files/MuMuPlayer/nx_main"; export MSYS_NO_PATHCONV=1
adb -s 192.168.100.62:5555 push <宿主>/tmp_qb16_book.txt  /sdcard/Download/tmp_qb16_book.txt
adb -s 192.168.100.62:5555 push <宿主>/x.png            /data/local/tmp/x.png
# 书架右上「更多」→「添加本地」→ 系统选择器搜索 tmp_qb16 → 选择文件
```

预置条件：验收开始前执行 `pm clear io.legado.flutter_legado` + `logcat -c`，从空书架冷启动（`tmp_qb16_01_home.png`）。

## 五、关键取证摘要

### 5.1 大图（A1/A2）

- 首屏（`tmp_qb16_06_ch1_open.png`）：标题「第一章 大图混排」→「前文字。」→ 800x600 蓝色测试图（黄框 + 对角黄线 + `BIG 800x600` 字样清晰）→「后文字。」；图片位于内容区左右边距之间，宽约 958px（1080 屏 − 左右各约 60px），高度按原比例约 718px；不存在 `<img>` 裸文本。
- 同一章节重新打开（`tmp_qb16_12_ch1_reopen_p1.png`）表现一致；宿主日志 `192.168.100.62 ... "GET /big.png" 200`（02:34:31、02:49:34）证明是设备真实取图，而非缓存占位。

### 5.2 小图行内（B3）

- `tmp_qb16_20_ch2_small_inline.png`：首行「行首文字：」+ 红色 40x40 方块 +「小图之后的文字」，随后同段文字继续换行；方块高度约占一行，未独占整行。
- `tmp_qb16_30_ch2_font24_page1.png`：字号 24 下仍保持行内，文字绕排正常。
- 宿主日志 `192.168.100.62 ... "GET /small.png" 200`（02:43:59）。

### 5.3 分页与丢字（C4/C5）— 核心缺陷证据

**现象**：含图片的章节翻页后，**非首页段落的首行前缀字符不可见**；语义树（`uiautomator dump`）中该前缀存在，但视觉上整行缺失（前后行距连续、无空行占位），等价于丢字。纯文本章节与对照书 2 未复现。

| 场景 | 证据 | 可见的段落起始 | 缺失字符 |
| --- | --- | --- | --- |
| 书1 章1，字号 20，第 2 页 | `tmp_qb16_07_ch1_page2.png`、`tmp_qb16_13_ch1_reopen_p2.png`（重复打开一致）、`ui_b16_ch1_p2.xml` | 第 2 段显示「段第2句：…」；第 3 段显示「是用于翻页…」 | 「第一大」（3 字）；「第一大段第3句：这」（9 字） |
| 书1 章1，字号 24，第 2 页（冷启动后） | `tmp_qb16_34_cold_ch1_p2.png`、`tmp_qb16_33_cold_ch1_p3.png` | 第 2 段显示「2句：…」；第 3 段显示「翻页对照的普通文本，内容与…」 | 「第一大段第」（5 字）；「第一大段第3句：这是用于」（12 字） |
| 书1 章2（小图），字号 20，第 2 页 | `tmp_qb16_21_ch2_page2.png`、`ui_b16_ch2_p1.xml` | 第 2 段「段为对照文本…」；第 3 段「段落3：…」；第 4 段「图章补充段落4：…」 | 10 字；5 字；1 字 |
| 书1 章2，字号 24，第 2 页 | `tmp_qb16_25_ch2_font24_p1.png` | 第 3 段「章补充段落3：…」；第 4 段「充段落4：…」 | 「小图」；「小图章补」 |
| 书1 章3（失效占位），字号 24，第 2 页 | `tmp_qb16_31_ch3_missing_p2.png` | 第 2 段「续段落2：…」；第 3 段「于确认图片加载失败后…」 | 4 字；10 字 |
| 对照：书1 章5 纯文本，字号 20/24 | `tmp_qb16_11_ch5_page2.png`（同页 3 段）、`tmp_qb16_27_ch5_font24_p1.png`、`ui_b16_ch5_p2.xml` | 「回归对照第3/4/5段…」全部完整 | 无 |
| 对照：书2 章1（同构造大图 + 10 段），字号 20 | `tmp_qb16_18_book2_ch1_p1.png`、`tmp_qb16_19_book2_ch1_p2.png`（同页 3 段）、`ui_b16_book2_ch1_p2.xml` | 「丙/丁/戊段标记…」全部完整，缩进正常 | 无 |

**判定**：该现象跨 3 个含图章节（大图 / 小图 / 失效占位）、两种字号、冷启动与重复打开均复现；语义树同屏文本中前缀仍在，说明排版模型未丢数据，但**用户可见文本缺失**，按设备判据「翻页不丢字」判 FAIL。

**页面利用率旁证**：含图章节首页只放 1 段（`tmp_qb16_20_ch2_small_inline.png`、`tmp_qb16_28_ch3_missing_p1.png` 余下约 60% 空白；`tmp_qb16_30_ch2_font24_page1.png` 在字号 24 下同样只放首段），与纯文本章节每页 2–3 段不一致，属同一排版批次问题的可见后果。

**对照书 2 未复现的线索（供开发定位，不作为结论）**：书 1 受影响段落均以「第一大段第N句」「小图章补充段落N」「失效章后续段落N」开头（含半角数字 N）；书 2 段落为「乙段标记：一二三…」，不含半角数字且未复现。当前证据只能说明缺陷**与文本度量/断行相关**，不能据此断言根因在数字分词。

### 5.4 失败占位（D6）

- `tmp_qb16_28_ch3_missing_p1.png`：`missing.png` 请求 404（宿主日志 02:46:50 / 02:48:21 / 02:49:19）后，页面渲染灰底占位块 + 破损图片图标（约 958×495），高度占用独立行；「占位前文字。」「占位后文字。」完整，后续内容可继续翻页（`tmp_qb16_31_ch3_missing_p2.png`），无异常日志。

### 5.5 `file://` 安全拒绝（E7）

- 设备内文件确证：`-rw-rw-rw- 1 shell shell 1639 2026-11-11 02:33 /data/local/tmp/x.png`（300x200 有效 PNG）。
- `tmp_qb16_29_ch4_file_local.png`：正文引用 `file:///data/local/tmp/x.png` 后显示与 D 相同的占位，**未显示绿色本地测试图**；「安全前文字。」「安全后文字。」完整，无崩溃。
- 结论：本地书正文对 `file://` 的目录围栏生效（拒绝书文件目录外的路径），符合批16「本地图片仅限书目录内」的安全约束。

### 5.6 纯文本回归（F8）

- 字号 20：首页 `tmp_qb16_10_ch5_plaintext.png`（2 段、缩进 2 字），第 2 页 `tmp_qb16_11_ch5_page2.png`（3 段，段首完整）。
- 字号 24：`tmp_qb16_27_ch5_font24_p1.png`（2 段，段首完整，行距随字号增大）。
- 结论：纯文本路径未见本批引入的丢字或分页异常（主观比对旧版排版一致）。

### 5.7 网络与安全旁证

`http_8091_b16.log`（宿主 python http.server 访问日志，设备侧来源 `192.168.100.62`）：

```
192.168.100.62 - - [11/Nov/2026 02:34:31] "GET /big.png HTTP/1.1" 200 -
192.168.100.62 - - [11/Nov/2026 02:43:59] "GET /small.png HTTP/1.1" 200 -
192.168.100.62 - - [11/Nov/2026 02:46:50] code 404 ... "GET /missing.png HTTP/1.1" 404 -
192.168.100.62 - - [11/Nov/2026 02:48:21] code 404 ... "GET /missing.png HTTP/1.1" 404 -
192.168.100.62 - - [11/Nov/2026 02:49:19] code 404 ... "GET /missing.png HTTP/1.1" 404 -
192.168.100.62 - - [11/Nov/2026 02:49:34] "GET /big.png HTTP/1.1" 200 -
```

说明：① 大图/小图/失效图均走真实 HTTP；② `file://` 用例未产生 HTTP 请求（与拒绝行为一致）；③ 02:33:13 三条来自宿主自身 `curl` 自检（`192.168.100.52`），不计入设备证据。

### 5.8 崩溃与内存（G9）

| 日志 | 行数 | `FATAL EXCEPTION` | `ANR in` | `E/flutter` | `overflowed` | `E AndroidRuntime` | `OutOfMemory` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `logcat_b16_session.txt`（02:33 起全时段） | 5,016 | 0 | 0 | 0 | 0 | 0 | 0 |
| `logcat_b16.txt`（清空后冷启动→章1翻页干净段） | 571 | 0 | 0 | 0 | 0 | 0 | 0 |

## 六、问题分级

### P1（阻塞）— 含图章节翻页后段落首行前缀不可见（丢字）

- 复现步骤：
  1. 导入 `tmp_qb16_book.txt`（或任何含 `<img>` 正文的本地 TXT），打开「第一章 大图混排」；
  2. 首屏正常（A1/A2），点按屏幕右侧翻到第 2 页；
  3. 观察第 2 段起：段落文字从中间开始显示（如「第一大段第2句：…」显示为「2句：…」），首行前缀整行不可见但行距无空档；
  4. 换字号（设置 → 字号 20→24）后重排，现象换形态继续存在；冷启动重进仍复现。
- 期望行为：段落首行完整显示（含 2 字缩进）；若空间不足应整段换页，不得丢弃/隐藏任何字符。
- 实际行为：前缀字符在视觉上缺失；语义树（`uiautomator dump`）中前缀仍在，说明是排版输出（首行宽度/行高）异常，而非正文数据损坏。
- 影响：正文内容缺失，违反批16 设备判据「翻页不丢字」；C4/C5 因此判 FAIL。
- 范围证据：3 个含图章节复现（大图 / 行内小图 / 失效占位）；纯文本章节与对照书 2 未复现。
- 定位线索（供开发，不构成结论）：`flutter_legado/lib/src/widgets/paragraph_layout_engine.dart` 的 `_guardLineOverflow`/`_breakZhLayout` 与 `reader_text_content.dart` 的行渲染路径；「首行只容纳 1–12 个字且无缩进」与「页首行零高度」两种形态提示首行可用宽/行高在页面拼接（`_splitTallParagraph`）后被改变。

### P2（重要）— 含图章节首页利用率异常

- 现象：含图章节第 1 页只放首段，余下约 60% 页面留白（`tmp_qb16_20_ch2_small_inline.png`、`tmp_qb16_28_ch3_missing_p1.png`、`tmp_qb16_30_ch2_font24_page1.png`），而纯文本章节同页可放 2–3 段。
- 期望：图片行之外的空间继续填充后续段落；实际：后续段落整体推到下一页，翻页次数偏多。
- 推测与本批「预测量后重排/分页」有关，属可见的排版质量问题（非崩溃）。

### P3（次要）— 单行图片旁文字呈拉伸分布

- 现象：`tmp_qb16_06_ch1_open.png` 中图片上方单行「前文字。」呈字距拉开的居中观感，与正文左对齐不一致（不影响可读性，主观项）。

## 七、设备终态

| 项目 | 结果 |
| --- | --- |
| `adb shell pm clear io.legado.flutter_legado` | `Success` |
| 进程 | `pidof` 无输出（已停止） |
| 当前焦点 | `mCurrentFocus=Window{... com.microsoft.launcher/com.microsoft.launcher.Launcher}` |
| 系统字体缩放 | `font_scale=1.0` |
| 屏幕 | 1080x1920 @480dpi（未变更） |
| 截图 | `tmp_qb16_35_terminal.png`（桌面） |
| 宿主 HTTP 服务 | 已停止（后台任务 `exec_469ab661-…` 终止）；访问日志已归档 `http_8091_b16.log` |
| 遗留测试文件（未删，便于复现） | `/sdcard/Download/tmp_qb16_book.txt`、`/sdcard/Download/tmp_qb16_book2.txt`、`/data/local/tmp/x.png`；宿主素材目录 `C:/Users/admin/AppData/Local/Temp/qb16_http`、`.../qb16_work` |

## 八、门禁引用与结论边界

**代码门禁（引用，非本轮重跑）**：提交 `65a21eafa7`（批16 三审回修）正文记录 `flutter analyze` 0、`flutter test` 5,569 通过 / 1 跳过、本批文件 `dart format` 0 changed；提交 `2795e47e65` 为本批收尾。

**本轮设备门禁（实测）**：五项崩溃计数 0、`OutOfMemory` 0、无 ANR/overlay overflow；`pm clear` 后终态正常。

**未验证/不声称通过**（检查不可用或未构造）：
1. 「真实在线阅读源正文含图」链路：本轮用本地 TXT 的 `<img>` 构造，未验证在线书源抓取后的图片基址绝对化（`chapter.baseUrl`）在设备上的表现；
2. 多图同章（≥6 图）并发测量与重排次数（提交正文所述 `maxActive==1` / ≤2 次重排）未在设备侧计量；
3. 图片点击五档行为与 action 执行通道（计划中明确不属本批）；
4. 图片缓存命中/解码失败的细分类（本轮仅验证了 HTTP 404 与 file:// 拒绝两种）；
5. 大图在「单页/滚动」等不同 `readConfig.imageStyle` 下的差异（本轮使用应用当前默认样式，未逐档切换）。

**验收结论**：图片渲染能力本身可用（大图/小图/占位/安全拒绝均符合预期，无崩溃），但文本完整性缺陷（P1）导致本批设备验收**不通过**；需修复含图章节翻页后段落首行丢字后再复验 C4/C5。

## 九、回修与复验（2026-11-11）

### 9.1 回修内容

| 缺陷 | 根因（代码级） | 修复 | 覆盖用例 |
| --- | --- | --- | --- |
| P1 含图章节翻页后段落首行前缀不可见 | `paragraph_layout_engine.dart::_splitParagraphsWithOffsets` 在正文含 `\n\n` 时只按空行分段；混排章节中「单换行分段 + 空行分隔段组」并存，单换行行被合并成一个超长段落，`\n` 作为普通字符留在 `LineInfo.words` 内。渲染侧 `Text(maxLines:1)` 只显示首个视觉行，换行后的段落前缀被裁掉；语义树仍含全文，故表现为「排版输出丢字」。 | 统一按 `\r?\n` 分段（空行由空白段过滤吸收），与上游 `splitNotBlank` 语义一致；每个 `LineInfo` 不再含换行符。 | 单测「混排章节跨页不丢字：行内无换行符且第 2 页首行前缀完整」；Widget「混排段落跨页不丢字：第 2 页首行前缀完整」 |
| P2 含图章节首页利用率异常 | 段落总高超过当前页剩余空间时，旧逻辑先 flush 当前页、再从整页起拆，导致图片段后大半页留白。 | `appendParagraph` 改为按当前页剩余容量切分首片并填入（不足一行才整段换页）；拆分后的最后一页保留为 current page，供后续段落继续填充。 | 单测「含图章节首页利用率：同页 ≥2 段」；Widget「图片段后继续放文本段」 |
| P3 图片旁单行文本被拉伸居中 | 含图片行的段落中，文本块末行仍按 `isLastLine/isSingleLine` 判定并参与两端对齐（图片行使段落行数>1）。 | 仅当「下一行仍是文本行」时两端对齐；文本块被图片行截断时按自然左对齐。 | Widget「图片旁单行文本不拉伸居中」 |

### 9.2 代码门禁（本轮重跑）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | 0 issues |
| `flutter test` | **5,574 通过 / 1 跳过 / 0 失败** |
| `dart format --set-exit-if-changed`（本批文件） | 0 changed |

新增用例：单测 2 例（跨页不丢字逐字符比对、首页利用率）、Widget 3 例（跨页前缀、首页利用率、单行不拉伸），均先在旧实现上红、修复后转绿。

### 9.3 APK 与设备复验

| 项目 | 值 |
| --- | --- |
| 回修提交 | `fix(ui): 批16 设备验收回修`（不改版本/ACTIVE_PLAN） |
| APK | `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`，sha256 `9943c4c66b1fe8be4cfeb44981a11803f29416b24affa53aca7d594c9d37bf06` |
| 安装 | `adb -s 192.168.100.62:5555 install -r` → `Success`（`versionName=2.0.485`、`versionCode=486`、`lastUpdateTime=2026-11-11 03:15:31`） |
| 复验设备 | MuMu「Test测试」`192.168.100.62:5555`，1080x1920@480dpi（360dp），`font_scale=1.0` |
| 复验素材 | 同 §一 测试书 1；宿主 HTTP `192.168.100.52:8091`（big/small/missing） |

**复验结果（全部 PASS）**

| 场景 | 字号 | 首页利用率 | 第 2 页文本完整性 | 证据 |
| --- | --- | --- | --- | --- |
| 章1 大图混排 | 20 | 图片段 + 「第一大段第1句」整段，页面填满 | 首行「第一大段第2句」完整（含 2 字缩进），后续段 3/4 完整 | `tmp_qb16_fix_32_ch1_font20_p1.png`、`tmp_qb16_fix_33_ch1_font20_p2.png` |
| 章1 大图混排 | 24 | 图片段 + 「第一大段第1句」前 4 行，页面填满 | 首行为第 1 段连续续行，随后「第一大段第2句」整行完整 | `tmp_qb16_fix_22_ch1_font24_p1_after_fill.png`、`tmp_qb16_fix_23_ch1_font24_p2_after_fill.png` |
| 章2 小图行内 | 20 | 首段 + 补充段落1/2/3（同页多段） | 续行 + 「小图章补充段落4」完整 | `tmp_qb16_fix_34_ch2_font20_p1.png`、`tmp_qb16_fix_35_ch2_font20_p2.png` |
| 章2 小图行内 | 24 | 首段 + 补充段落1/2，行内小图仍与文字同行 | 「小图章补充段落3/4」完整 | `tmp_qb16_fix_24_ch2_font24_p1_after_fill.png`、`tmp_qb16_fix_25_ch2_font24_p2_after_fill.png` |
| 章3 失效占位 | 20 | 占位图段 + 后续段落1/2，页面填满 | 「失效章后续段落3/4」完整 | `tmp_qb16_fix_36_ch3_font20_p1.png`、`tmp_qb16_fix_37_ch3_font20_p2.png` |
| 章3 失效占位 | 24 | 占位图段 + 段落1 + 段落2 首行 | 续行 + 「失效章后续段落3/4」完整 | `tmp_qb16_fix_26_ch3_font24_p1_after_fill.png`、`tmp_qb16_fix_27_ch3_font24_p2_after_fill.png` |
| 冷启动（章1） | 24 | `force-stop` 后重启进入章1，首页填充正常 | 翻页无前缀缺失；序列 `fix_21 → fix_22 → fix_23` | `tmp_qb16_fix_21_home_after_fill.png` 等 |
| P3 单行「前文字。」 | 20/24 | 左对齐自然排列，未拉伸居中 | — | `tmp_qb16_fix_32_ch1_font20_p1.png`、`tmp_qb16_fix_22_ch1_font24_p1_after_fill.png` |

**日志与终态**

| 项目 | 结果 |
| --- | --- |
| `logcat_b16_fix.txt`（回修后全时段，2,060 行） | `FATAL EXCEPTION`=0、`ANR in`=0、`E/flutter`=0、`overflowed`=0、`E AndroidRuntime`=0、`OutOfMemory`=0 |
| 清理 | `pm clear io.legado.flutter_legado` → `Success`；进程已停止 |
| 宿主 HTTP | 已停止（8091 无 LISTENING） |

### 9.4 复验结论

P1 首行前缀丢失、P2 首页利用率、P3 单行拉伸三项均已在 MuMu 测试机按「大图章/小图章/占位章 × 字号 20/24 × 冷启动」复验通过；C4/C5 由 FAIL 转为 **PASS**。本批设备验收结论更新为 **PASS**。

未改变项：图片点击五档/action 通道、真实在线阅读源图片基址、`imageStyle` 逐档差异仍按 §八「未验证/不声称通过」口径保留。
