# 静态能力对账报告

- 语料：`D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-ffi\../..\.tmp\corpus\yckceo_1283.json`（916 源）
- 含 JS 片段源数：916
- 耗时：0.32s
- 能力面快照：quickjs_impl.rs 164 个宿主函数（双挂载 java.*/裸全局）
- 文件门控（生产未注册）：9

## 片段命中

| 片段 | 出现源数 |
|---|---|
| exploreUrl | 661 |
| jsLib | 45 |
| loginUrl | 133 |
| ruleBookInfo | 5156 |
| ruleContent | 1617 |
| ruleSearch | 6200 |
| ruleToc | 3104 |
| searchUrl | 915 |

## 缺失符号排行（静态，按引用源数）

| 符号 | 源数 | 状态 | 可实现性评估 | 示例源 |
|---|---|---|---|---|
| `java.searchBook` | 5 | 缺失 | 可评估：默认按纯计算/字符串处理 | #7 🎬奈飞工厂 / https://www.netflixgc.com；#15 🎬📷终极全栖接口聚合 / 苹果通用API接口聚合；#25 ⚡📂听小说APP / https://ts3.txs12.com |
| `cache.getFromMemory` | 4 | 缺失 | 可评估：默认按纯计算/字符串处理 | #20 🔞Linpx / https://furrynovel.ink；#36 🏷微信读书二合一本地源 / https://i.weread.qq.com；#101 🎨漫蛙动漫 / https://manwaza.cc#大改 |
| `cache.putMemory` | 4 | 缺失 | 可评估：默认按纯计算/字符串处理 | #20 🔞Linpx / https://furrynovel.ink；#36 🏷微信读书二合一本地源 / https://i.weread.qq.com；#101 🎨漫蛙动漫 / https://manwaza.cc#大改 |
| `cookie.getKey` | 4 | 缺失 | 难：需真实 JVM/IO/网络栈（建议宿主桥接或标记不支持） | #94 🏷起点(部分可看) / https://m.qidian.com##限免部分书；#135 🏷阅文集团 / https://www.yuewen.com#🎃；#147 🏷晋江文学（个人自用） / https://m.jjwxc.net/channel/#修改版 |
| `java.open` | 3 | 缺失 | 可评估：默认按纯计算/字符串处理 | #20 🔞Linpx / https://furrynovel.ink；#302 🔞兽人小说站 / https://furrynovel.com；#583 🎬🏷哔哩哔哩 / https://www.bilibili.com |
| `cache.deleteMemory` | 2 | 缺失 | 可评估：默认按纯计算/字符串处理 | #20 🔞Linpx / https://furrynovel.ink；#36 🏷微信读书二合一本地源 / https://i.weread.qq.com |
| `com.kmxs.reader` | 2 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #170 🏷七猫四合一本地版 / 七猫四合一本地版；#619 🏷七猫四合一本地版（同人） / 七猫四合一本地版（同人） |
| `Jsoup.parse` | 1 | 缺失（无裸全局 jsoup 标识符，需 org.jsoup. 前缀） | 可评估：默认按纯计算/字符串处理 | #6 ⚡📂77读书 / http://www.77shuku.info |
| `Packages.android.graphics` | 1 | 缺失 | 可评估：默认按纯计算/字符串处理 | #58 🎨🔞禁漫天堂 / https://jmcomicui.net |
| `Packages.android.graphics.BitmapFactory.decodeStream` | 1 | 缺失 | 难：需真实 JVM/IO/网络栈（建议宿主桥接或标记不支持） | #389 🔞爱腐文 / https://yanyan.life/ |
| `Packages.android.text.TextUtils.isEmpty` | 1 | 缺失 | 可评估：默认按纯计算/字符串处理 | #135 🏷阅文集团 / https://www.yuewen.com#🎃 |
| `Packages.okhttp3` | 1 | 缺失 | 难：需真实 JVM/IO/网络栈（建议宿主桥接或标记不支持） | #135 🏷阅文集团 / https://www.yuewen.com#🎃 |
| `Packages.okhttp3.OkHttpClient` | 1 | 缺失 | 难：需真实 JVM/IO/网络栈（建议宿主桥接或标记不支持） | #704 📂️醉读小说️# / https://wap.maxreader.la |
| `Packages.okhttp3.Request` | 1 | 缺失 | 难：需真实 JVM/IO/网络栈（建议宿主桥接或标记不支持） | #704 📂️醉读小说️# / https://wap.maxreader.la |
| `android.goreadnovels.com` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #205 ⚡📂绿柠小说 / https://android.goreadnovels.com |
| `android.jjwxc.com` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #147 🏷晋江文学（个人自用） / https://m.jjwxc.net/channel/#修改版 |
| `android.jjwxc.net` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #147 🏷晋江文学（个人自用） / https://m.jjwxc.net/channel/#修改版 |
| `cache.dev_id` | 1 | 缺失 | 可评估：默认按纯计算/字符串处理 | #25 ⚡📂听小说APP / https://ts3.txs12.com |
| `cn.baozimh.com` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #511 🎨包子漫画 / https://cn.webmota.com |
| `cn.bzmgcn.com` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #62 🎨包子漫画（优） / https://cn.bzmgcn.com |
| `cn.dzmanga.com` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #910 🎨包子漫画（优+） / https://cn.bzmanga.com |
| `cn.webmota.com` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #511 🎨包子漫画 / https://cn.webmota.com |
| `cn.zhys.tw` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #34 🔑免费小说 / https://cn.zhys.tw |
| `com.listenxs.txsplayer` | 1 | 缺失（仅 Packages. 前缀可用） | 可：纯计算/字符串（Rust 可实现） | #25 ⚡📂听小说APP / https://ts3.txs12.com |
| `com.martian.ttbook` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #353 📂淘小说优 / https://tybook.taoyuewenhua.net |
| `com.se6d37e1cb.n2e98606a2.zf47af499020250314` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #512 🔞Jk小说 / https://rrs0c03ak.fssd5ib.com |
| `com.sing.client.player` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #804 🔊五丁音乐 / http://5sing.kugou.com |
| `com.vivo.vreader` | 1 | 缺失（仅 Packages. 前缀可用） | 可评估：默认按纯计算/字符串处理 | #209 ⚡📂趣悦小说 / https://vreader.vivo.com.cn/ |
| `com.zhuxshah.mszlhdgwa` | 1 | 缺失（仅 Packages. 前缀可用） | 可：纯计算/加解密（Rust crypto 库可实现） | #731 📂猪猪小说#1 / https://gg.zzxsa.com#🎃 |
| `cookie.mapToCookie` | 1 | 缺失 | 难：需真实 JVM/IO/网络栈（建议宿主桥接或标记不支持） | #57 🌍🔞爱丽丝书屋 / https://www.alicesw.com |
| `cookie.replaceCookie` | 1 | 缺失 | 难：需真实 JVM/IO/网络栈（建议宿主桥接或标记不支持） | #57 🌍🔞爱丽丝书屋 / https://www.alicesw.com |
| `cookie.split` | 1 | 缺失 | 难：需真实 JVM/IO/网络栈（建议宿主桥接或标记不支持） | #57 🌍🔞爱丽丝书屋 / https://www.alicesw.com |
| `java.HMacBase64` | 1 | 缺失 | 可：纯计算/加解密（Rust crypto 库可实现） | #135 🏷阅文集团 / https://www.yuewen.com#🎃 |
| `java.base64Decoder` | 1 | 缺失 | 可：纯计算/加解密（Rust crypto 库可实现） | #561 ⚡📂顾淮小说 / https://read.xiaoshuo1-sm.com |
| `java.headerMap.put` | 1 | 缺失（仅 Packages. 前缀可用） | 可：纯计算/字符串（Rust 可实现） | #286 📂刚够小说网 / https://m.ganggou.net/ |
| `java.hexEncodeToString` | 1 | 缺失 | 可：纯计算/字符串（Rust 可实现） | #324 🏷长佩文学 / https://www.gongzicp.com |
| `java.openWeb` | 1 | 缺失 | 可评估：默认按纯计算/字符串处理 | #42 🎬🔞黄豆短剧 / https://huangdoudj.com |
| `java.showPhoto` | 1 | 缺失 | 可评估：默认按纯计算/字符串处理 | #583 🎬🏷哔哩哔哩 / https://www.bilibili.com |
| `java.sleep` | 1 | 缺失 | 可评估：默认按纯计算/字符串处理 | #45 🎭🎬露西弗俱乐部 / https://lucifer-club.com |
| `java.tripleDESEncodeBase64Str` | 1 | 缺失 | 可：纯计算/加解密（Rust crypto 库可实现） | #135 🏷阅文集团 / https://www.yuewen.com#🎃 |
| `java.url` | 1 | 缺失 | 难：需真实 JVM/IO/网络栈（建议宿主桥接或标记不支持） | #286 📂刚够小说网 / https://m.ganggou.net/ |

## 已提供但被引用的裸宿主函数（TOP 40）

| 函数 | 源数 | 示例源 |
|---|---|---|
| `ajax` | 184 | #1 🏷七猫小说·API；#2 📂台湾小说网；#8 📂11看书 |
| `getString` | 103 | #0 📂绿色小说；#1 🏷七猫小说·API；#17 🏷松鹤庭沐·言璃 |
| `get` | 97 | #1 🏷七猫小说·API；#2 📂台湾小说网；#6 ⚡📂77读书 |
| `log` | 96 | #8 📂11看书；#20 🔞Linpx；#26 🏷书旗小说 |
| `put` | 81 | #1 🏷七猫小说·API；#8 📂11看书；#12 📂霹雳书屋 |
| `removeCookie` | 73 | #22 📂女生文学#书源.com；#45 🎭🎬露西弗俱乐部；#57 🌍🔞爱丽丝书屋 |
| `toast` | 61 | #2 📂台湾小说网；#7 🎬奈飞工厂；#12 📂霹雳书屋 |
| `base64Decode` | 52 | #7 🎬奈飞工厂；#26 🏷书旗小说；#45 🎭🎬露西弗俱乐部 |
| `getVariable` | 43 | #1 🏷七猫小说·API；#7 🎬奈飞工厂；#15 🎬📷终极全栖接口聚合 |
| `getElements` | 36 | #12 📂霹雳书屋；#19 🎨🔞18色漫画；#62 🎨包子漫画（优） |
| `encodeURIComponent` | 35 | #1 🏷七猫小说·API；#7 🎬奈飞工厂；#15 🎬📷终极全栖接口聚合 |
| `longToast` | 35 | #12 📂霹雳书屋；#19 🎨🔞18色漫画；#20 🔞Linpx |
| `md5Encode` | 34 | #25 ⚡📂听小说APP；#26 🏷书旗小说；#58 🎨🔞禁漫天堂 |
| `createSymmetricCrypto` | 28 | #47 🎨漫蛙；#55 ⚡📂丁丁小说；#57 🌍🔞爱丽丝书屋 |
| `base64Encode` | 26 | #20 🔞Linpx；#26 🏷书旗小说；#36 🏷微信读书二合一本地源 |
| `setVariable` | 26 | #1 🏷七猫小说·API；#7 🎬奈飞工厂；#15 🎬📷终极全栖接口聚合 |
| `timeFormat` | 24 | #1 🏷七猫小说·API；#17 🏷松鹤庭沐·言璃；#20 🔞Linpx |
| `refreshExplore` | 23 | #1 🏷七猫小说·API；#7 🎬奈飞工厂；#15 🎬📷终极全栖接口聚合 |
| `encodeURI` | 22 | #12 📂霹雳书屋；#36 🏷微信读书二合一本地源；#98 ⚡📂全本小说 |
| `post` | 21 | #36 🏷微信读书二合一本地源；#44 🎭🎬露西弗同人站；#57 🌍🔞爱丽丝书屋 |
| `setContent` | 20 | #12 📂霹雳书屋；#28 📘哔哩轻小说；#57 🌍🔞爱丽丝书屋 |
| `connect` | 19 | #57 🌍🔞爱丽丝书屋；#70 ⚡📂盗版顶点；#109 📂八一中文 |
| `toNumChapter` | 19 | #82 📂格格党[分页]；#162 📂顶点小说；#203 📂格格党haogshi88 |
| `startBrowser` | 17 | #2 📂台湾小说网；#20 🔞Linpx；#39 🎬🔞麻豆传媒AI |
| `hexDecodeToString` | 16 | #1 🏷七猫小说·API；#36 🏷微信读书二合一本地源；#57 🌍🔞爱丽丝书屋 |
| `webView` | 16 | #20 🔞Linpx；#124 ⚡📂听笔趣阁；#136 📂棉花糖 |
| `aesBase64DecodeToString` | 15 | #182 🔞PO5；#279 ⚡📂小小阅读（+++）；#284 ⚡📂猫眼看书（+++） |
| `base64DecodeToByteArray` | 15 | #36 🏷微信读书二合一本地源；#38 🎨卡拉漫画；#55 ⚡📂丁丁小说 |
| `startBrowserAwait` | 15 | #12 📂霹雳书屋；#36 🏷微信读书二合一本地源；#44 🎭🎬露西弗同人站 |
| `getElement` | 13 | #28 📘哔哩轻小说；#57 🌍🔞爱丽丝书屋；#128 📂欧诺文学 |
| `t2s` | 13 | #2 📂台湾小说网；#20 🔞Linpx；#62 🎨包子漫画（优） |
| `getCookie` | 12 | #45 🎭🎬露西弗俱乐部；#57 🌍🔞爱丽丝书屋；#88 📂完本神站（登录） |
| `getStringList` | 10 | #47 🎨漫蛙；#260 🎬艾格动漫；#285 📂笔趣阁_书友 |
| `timeFormatUTC` | 9 | #26 🏷书旗小说；#135 🏷阅文集团；#172 🔊懒人听书 |
| `refreshTocUrl` | 8 | #57 🌍🔞爱丽丝书屋；#208 ⚡📂点众阅读；#259 📚聚合书库 |
| `setCookie` | 8 | #45 🎭🎬露西弗俱乐部；#57 🌍🔞爱丽丝书屋；#318 📂无忧书城（优） |
| `upLoginData` | 8 | #26 🏷书旗小说；#30 ⚡📂米读小说；#36 🏷微信读书二合一本地源 |
| `openUrl` | 7 | #20 🔞Linpx；#30 ⚡📂米读小说；#39 🎬🔞麻豆传媒AI |
| `replaceAll` | 7 | #57 🌍🔞爱丽丝书屋；#132 🔞蛋文库；#244 🏷可阅文学 |
| `strToBytes` | 7 | #362 📂青藤文学；#389 🔞爱腐文；#502 🔞情幻文学 |

## 观察名单命中（未注册符号）

| 符号 | 源数 | 示例源 |
|---|---|---|
| `eval(` | 66 | #20 🔞Linpx；#26 🏷书旗小说；#57 🌍🔞爱丽丝书屋 |

\* 文件门控：`allow_file_access=false`（生产），该函数实际未注册，源引用即缺口。
