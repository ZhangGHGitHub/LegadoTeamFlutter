# legado-fetcher 测试夹具

本目录为 `legado-fetcher` 自持测试夹具（P2-1：消除对 `legado-ffi/tests/` 的跨 crate
目录引用，保证 fetcher 可独立移动/裁剪、稀疏检出下测试不挂）。

夹具均为**采集自真实站点的逐字数据**，请勿手改字节（含格式化）；如需更新请重新采集
并同步更新本文件中的 sha256。

## 清单

| 文件 | 消费测试（`src/web_book.rs`） | 来源 |
|---|---|---|
| `source_shoujixiaoshuo_sjshuku.json` | `test_shoujixiaoshuo_tocurl_bridge_before_after`（P2-9③） | 真实书源表「手机小说」条目逐字提取；原位于 `legado-ffi/tests/fixtures/`，P2-1 迁移至本目录后删除 ffi 副本 |
| `jhsu_book4cc_source.json` | `test_p29_real_jhsu_source_before_after` | q9.db `book_sources` 逐字 JSON（📚聚合书库）；原位于 `legado-ffi/tests/fixtures/`，P2-1 迁移后删除 ffi 副本（`legado-parser/src/rule_analyzer.rs` 仅注释提及，无文件依赖） |
| `fixtures_95590_ch9.html` | `test_parse_content_page_real_95590_entry_content` | 真实 95590 章节页（原文件在 `legado-ffi/tests/` 根下，非 fixtures/ 子目录）；P2-1 迁移后删除 ffi 副本 |
| `qmao_play_full.html` | `qmao_js_rule_extracts_m3u8_from_saved_html` | 真实伪七猫 play 页；原位于 `legado-ffi/tests/fixtures/`，P2-1 迁移后删除 ffi 副本 |
| `qmao_min_source.json` | `qmao_js_rule_extracts_m3u8_from_saved_html` | 伪七猫最小书源；**ffi 侧仍在使用**（`legado-ffi/src/api/web_book.rs` 测试），ffi 保留原文件 |

sha256（2026-10-01 P2-1 迁移时）：

```
700421b88f3fd4f7efb30cfcc665f00d35bb6c3f09f9f0ccf52bcc5253389291  source_shoujixiaoshuo_sjshuku.json
6235686144857e39f878791b63d2e1219ab13fd1fe2b2c083d88f3428e399fcd  jhsu_book4cc_source.json
c68bd1140744902684a92ea6a46cb15891f65431008756beef310f9b15610385  fixtures_95590_ch9.html
135e1c59f2697c25e84620448bbebea8259e7c0865108de9189fe2f6ceab707a  qmao_play_full.html
d6b6846cba2e4ff5ff87277876695194e0e8d3b3acf3cd7bb053c37151f2eb72  qmao_min_source.json
```

## 双同步纪律

- `qmao_min_source.json` 为 fetcher 与 `legado-ffi` **双方持有**的同源副本：任何改动
  必须双处同步（本目录与 `legado-ffi/tests/fixtures/qmao_min_source.json`），并同步
  更新本文件 sha256。fetcher 引用处（`src/web_book.rs`）已标注该约束。
- 其余四个文件 ffi 侧已无引用并删除，fetcher 为唯一持有者；如未来 ffi 需要复用，
  请直接从本目录复制一份自持副本，不要写跨 crate 相对路径。
- 本目录不新增跨 crate 反向引用；fetcher 测试只允许引用本目录内的路径
  （`include_str!("../tests/fixtures/…")` / `concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/…")`）。
