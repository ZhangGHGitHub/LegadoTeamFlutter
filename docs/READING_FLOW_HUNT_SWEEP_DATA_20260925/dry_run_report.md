# 离线干跑报告（全语料 916 源，耗时 1.6s）

- 引擎：生产同源 QuickJsEngine（allow_script_run=true，64MB，5s/eval）
- 网络：全部宿主网络/浏览器/睡眠函数替换为记录器（零真实联网）
- 隔离：每源独立线程，panic → d 类

## 分类统计

| 类别 | 源数 |
|---|---|
| ok-离线可跑 | 856 |
| c-需网络/登录(离线不可判) | 48 |
| b-JS错误 | 12 |

## 缺失 Java 能力排行（a 类，按源数）

| # | 符号 | 源数 | 可实现性 | 示例源 |
|---|---|---|---|---|

## JS 错误签名 TOP 20（b 类）

| # | 错误签名 | 源数 | 示例源 |
|---|---|---|---|
| 1 | `jsLib：JS engine error: expecting ';' (at eval_script:1:1)` | 3 | #463 🔞月色书屋；#658 📂情言小说；#674 📂闪爵小说 |
| 2 | `searchUrl JS：JS engine error: not a function (at bind (native)
    at _0xeab7ca (eval_script:3:22863)
    at _0x605728 (eval_script:3:10542)
    at _0xeab7ca (e` | 2 | #626 📂69书吧-H；#888 📂69書吧 |
| 3 | `jsLib：JS engine error: JavaImporter is not defined (at <eval> (eval_script:1:21))` | 1 | #634 ⚡📂得间免费小说 |
| 4 | `jsLib：JS engine error: JavaImporter is not defined (at <eval> (eval_script:70:14))` | 1 | #135 🏷阅文集团 |
| 5 | `jsLib：JS engine error: invalid redefinition of parameter name (at eval_script:36:5)` | 1 | #26 🏷书旗小说 |
| 6 | `jsLib：JS engine error: invalid redefinition of parameter name (at eval_script:39:5)` | 1 | #324 🏷长佩文学 |
| 7 | `jsLib：JS engine error: invalid redefinition of parameter name (at eval_script:96:5)` | 1 | #583 🎬🏷哔哩哔哩 |
| 8 | `searchUrl JS：JS engine error: invalid redefinition of global identifier (at eval_script:25:1)` | 1 | #850 📂爱巴士 |
| 9 | `searchUrl JS：JS engine error: redeclaration of 'baseUrl' (at <eval> (eval_script:1:1))` | 1 | #702 📂乐乎文章（优） |

## 触网示例（c 类，离线不可判）

- #28 📘哔哩轻小说（2 次网络调用）
- #33 📂白鹿书院（9 次网络调用）
- #36 🏷微信读书二合一本地源（0 次网络调用）
- #66 ⚡📂笔趣全家桶（2 次网络调用）
- #108 📂天悦小说（1 次网络调用）
- #124 ⚡📂听笔趣阁（2 次网络调用）
- #136 📂棉花糖（1 次网络调用）
- #169 📂燃文小说（无搜索）（1 次网络调用）
- #170 🏷七猫四合一本地版（1 次网络调用）
- #219 ⚡📂米读小说（1 次网络调用）
- #229 📂冰清阁小说（1 次网络调用）
- #235 📂小书本网（1 次网络调用）
- #241 📥伪书香（1 次网络调用）
- #245 ⚡📂全本小说（1 次网络调用）
- #257 ⚡📂笔趣全家桶（2 次网络调用）
- #260 🎬艾格动漫（1 次网络调用）
- #288 🎭全本同人小说网（1 次网络调用）
- #292 📂书城（1 次网络调用）
- #294 📂趣又来吧（1 次网络调用）
- #318 📂无忧书城（优）（1 次网络调用）
