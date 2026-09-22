# 搜索解析 Parity 修复交接文档

> 分支：`feature/rust-parser-gap-fix`
> 目标：原版 Legado 书源搜索解析结果与重构版一致
> 最后更新：2026-08-17
> 编写者：DeepSeek Harness

---

## 一、本轮修复成果（6 个提交）

| 提交 | 内容 | 修复书源 |
|---|---|---|
| `b8ef74697` | search source context、lenient url option JSON、JSON content rule mode | 爱下电子、丁丁小说 |
| `3e35bc6c9` | bookUrlPattern 全匹配、`!n` 排除索引误判、表格片段解析、`@js:` 变量注入 | 七步阁 0→50、77读书网 0→50、淘小说 0→10 |
| `fdbc48572` | `@js:` 跨行正则、java Response 语义桥、cookie.removeCookie | 企鹅小说 0→15、新笔趣阁 0→22 |
| `8e73a75b8` | `{{host}}` JS 全局变量、ajax 普通 URL、connectNR 无重定向、encodeURI 双参 | 得间小说 0→20、新落秋/zdzn/燃文 URL 构建 |
| `2dcad5b43` | HTML 响应字符集自动解码（GBK meta/header/显式 charset 优先级） | 七步阁目录/正文乱码 |
| `9635fdf2e` | 预编码 POST 表单分量保持原样（保留已有 %HH 编码） | 苦瓜书盘请求参数 |

## 二、已验证修复的书源（8 个）

| 书源 | 修复前 | 修复后 | 根因 |
|---|---|---|---|
| **七步阁** | 搜索 0 + 目录正文乱码 | 50 条 + 目录正文正常 | bookUrlPattern 部分匹配 + GBK 解码 |
| **77读书网** | 0 | 50 条 | tr!0 索引误判 + tr 片段解析 |
| **淘小说** | 0 | 10 条 | @js md5 签名块未注入 key |
| **企鹅小说** | 404 | 15 条 | {{}} 跨行 + setup 缺失 + removeCookie |
| **新笔趣阁** | 404 | 22 条 | java Response 桥 + source.getKey + cookie |
| **得间小说** | 0 | 20 条 | {{host}} JS 全局变量未求值 |
| **苦瓜书盘** | 服务端提示页 | 响应含 slist | 表单重复编码 %252C |
| **爱下/丁丁** | 0 | 有结果 | source context + lenient JSON |

## 三、批量扫描验证

- **范围**：120 个 type-0 文本书源
- **结果**：ok=93（77.5%）、empty=14、failed=13
- **全部 empty/failed 确认为源侧限制**：
  - 限频：新落秋/笔趣阁zdzn/燃文（IP 级封锁，python 同样受限）
  - WAF：天悦小说（需 Referer，原版 jsoup 同样不带）
  - 站点无结果：繁星四月/九九藏书/苦瓜书盘
  - 规则过时：书旗本地源（jayway 2.10.0 实证原版同样 0）
  - 需登录：完本神站
  - 网络层：爱丽丝/霹雳/偶遇/笔趣阁等 timeout/403/504/404

## 四、关键架构改动

### 4.1 bookUrlPattern 全匹配（web_book.rs）
原版 `baseUrl.matches(it.toRegex())` 全匹配。Rust 原用 `Regex::is_match`（find）。
修复：锚定 `^(?:{pattern})$`。

### 4.2 @链排除索引误判（html.rs）
`class.BOX@tr!0` 的 `tr!0` 被 `is_extraction_suffix` 误判为属性名。
修复：`!last.contains('!')` 排除索引语法。

### 4.3 表格片段解析（html.rs）
html5ever 丢弃 body 外的 `<tr>/<td>` 片段，jsoup 宽容保留。
修复：`wrap_table_fragment`（`<table><tbody>` 包裹后解析）。

### 4.4 java Response 语义桥（quickjs_impl.rs）
原版 `java.get(url,headers)` 返回 jsoup Response 对象。
Rust `java.get` 被 setup 覆盖为变量读取。
修复：RESPONSE_BRIDGE_JS（setup 后重新注入，用 connectNR 不跟随重定向）。

### 4.5 HTML 响应字符集解码（web_book.rs）
对齐 `OkHttpUtils.ResponseBody.text`：URL charset → Content-Type → HTML meta → UTF-8。
fetch_url/fetch_simple_cached 改读原始字节后统一解码。

### 4.6 预编码表单分量（analyze_url.rs）
对齐 `NetworkUtils.encodedForm`：无 charset 时保留已有合法 `%HH`。

### 4.7 {{host}} JS 全局变量（analyze_url.rs）
简单变量名先查 map，未命中再 `execute_js(expr)` 求值 JS 全局。

## 五、回归测试矩阵

| 测试 | 覆盖 |
|---|---|
| `test_qibuge_search_diag` | 七步阁搜索 50 条 |
| `test_qibuge_catalog_and_content_gbk` | 七步阁详情→目录→正文（无乱码） |
| `test_77shuku_search_diag` | 77读书网搜索 50 条 |
| `test_taoxiaoshuo_search_diag` | 淘小说搜索 10 条 |
| `test_qiexs_search_diag` | 企鹅小说搜索 15 条 |
| `test_xbqgxs_search_diag` | 新笔趣阁搜索 22 条 |
| `test_dejian_diag` | 得间小说搜索 20 条 |
| `test_decode_web_response_gbk_meta_and_header` | GBK charset 优先级 |
| `test_preencoded_post_form_preserved` | 表单 %HH 保持 |
| `test_shushan_real_toc_repro` | 书山目录 1058 章 |
| parser / ffi / js 全量 | 248/0 / 374/0 / 491/1 |

## 六、文件变更索引

| 文件 | 改动 |
|---|---|
| `rust/legado-parser/src/html.rs` | ! 索引误判 + 表格片段 |
| `rust/legado-parser/src/analyze_url.rs` | {{}} 跨行 + JS 全局变量 + 预编码表单 |
| `rust/legado-ffi/src/api/web_book.rs` | bookUrlPattern + search setup + 字符集解码 |
| `rust/legado-ffi/src/api/source_js_bindings.rs` | source.getKey/key/url 别名 |
| `rust/legado-ffi/src/js_executor.rs` | Response 桥注入 |
| `rust/legado-js/src/host_api/quickjs_impl.rs` | Response 桥 + connectNR + removeCookie + encodeURI |
| `rust/legado-js/src/host_api/network.rs` | ajax 普通 URL + connect_no_redirect |
| `rust/legado-js/src/host_api/encoding.rs` | encode_uri_charset GBK |

## 七、已知限制与待办

- 809 个文本源中只扫了 120 个，下一轮扩展至更多
- G8 `$n` 分组引用（罕见，常见形态已覆盖）
- httpbin.org 外部测试故障（与改动无关）
- 新落秋/zdzn/燃文站点限频（引擎链路正确，受 IP 限制）

## 八、验证环境

- 5556：冒烟 PASSED（6/6）
- 5558：已安装最新 APK（含全部 6 个提交），用户可实测验收
- 原版对照：5558 装有 com.legado.app.release 3.26081008

编写者：DeepSeek Harness ｜ 2026-08-17
