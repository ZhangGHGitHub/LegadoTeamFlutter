# 阶段 02 落盘：静态能力对账结论（916 源语料）

> 生成：`cargo test -p legado-ffi --features quickjs --test capability_sweep`（静态测试，0.4s 通过）
> 完整表见 `static_report.md` / `static_report.json`（本文件只记关键结论，防中断抢救用）。

## 1. 片段命中（全 916 源均含 JS 片段）

| 片段 | 源数 | 片段 | 源数 |
|---|---|---|---|
| ruleSearch | 6200 | ruleBookInfo | 5156 |
| ruleToc | 3104 | ruleContent | 1617 |
| loginUrl | 133 | exploreUrl | 661 |
| searchUrl | 915 | jsLib | 45 |

## 2. 已修正的静态误报（本次会话）

- **命名空间前缀不再计缺失**：`Packages.java.lang / java.util / java.io / java.nio / java.security /
  javax.crypto / android.util / cn.hutool / org.jsoup` 命名空间对象在生产 `__pkRoot` 树中真实存在，
  仅未知叶子触发 `reportUnknownSymbol` 陷阱 → 新增 `PACKAGES_KNOWN_NS` 常量，状态改「提供（命名空间前缀）」。
- **裸 java 镜像**：`java.lang` / `java.security` 同时挂在裸 `java` 全局（quickjs_impl.rs 镜像段）→
  新增 `BARE_JAVA_MIRROR_NS` 常量，不再误判。
- **`java.searchBook` 确认为真缺失**：全仓 grep 无 `function searchBook` 注册（原版为 Android 搜索
  作用域注入；我方搜索 JS 作用域未提供）→ 5 源受影响。

## 3. 静态缺失符号（修正后，按源数）——关键项

| 符号 | 源数 | 备注 |
|---|---|---|
| `java.searchBook` | 5 | 真缺失：搜索作用域未注入 searchBook(list) 结果提交函数 |
| `cache.getFromMemory` / `putMemory` | 4 / 4 | cache 对象只有 get/put/remove/delete/getFile/putFile（原版有 Memory 三件套） |
| `cookie.getKey` | 4 | cookie 对象缺 getKey（原版 CookieManager 有） |
| `java.open` | 3 | 未注册的宿主函数（浏览器打开） |
| `cache.deleteMemory` | 2 | 同 getFromMemory 家族 |
| `com.kmxs.reader`（Packages.） | 2 | 七猫本地源专用包（本地应用包，确认不做候选） |
| `Jsoup.parse`（裸全局） | 1 | 77读书：无裸 `jsoup` 标识符，需 org.jsoup. 前缀（用户报障②同源） |
| `Packages.android.graphics(.BitmapFactory.decodeStream)` | 1 | 图片解码（爱腐文） |
| `Packages.android.text.TextUtils.isEmpty` | 1 | 纯计算可实现 |
| `Packages.okhttp3(.OkHttpClient/.Request)` | 3 | 需真实 HTTP 栈（阅文/醉读），确认不做候选 |
| `cookie.mapToCookie/replaceCookie/split` | 各 1 | 爱丽丝书屋 cookie 工具方法 |
| `java.HMacBase64` / `java.tripleDESEncodeBase64Str` | 各 1 | 阅文：Rust crypto 可实现（HMAC/3DES） |
| `java.base64Decoder` / `java.hexEncodeToString` | 各 1 | 顾淮/长佩：纯计算可实现 |
| `java.headerMap.put` | 1 | headerMap 请求头 Map 未提供 |
| `java.openWeb` / `java.showPhoto` / `java.sleep` / `java.url` | 各 1 | 浏览器/显示/URL 工具 |

## 4. 已知噪声（干跑裁定，不入分诊）

- 域名字符串误报：`cn.baozimh.com` / `android.jjwxc.com` / `com.vivo.vreader` / `com.martian.ttbook`
  等 `cn|com|android.<域名>` 形态——实为 URL/域名 token，非 Java 类引用；字符串字面量内引用
  不会触发陷阱，干跑不会报错。
- `com.se6d37e1cb...` 等混淆包名：本地应用源专用，确认不做候选。

## 5. 下一步

全量离线干跑（`-- --ignored`，4 路并发池，网络函数记录器桩）→ 分类 a/b/c/d →
`dry_run_report.md` / `dry_run_details.json` → report_03。
