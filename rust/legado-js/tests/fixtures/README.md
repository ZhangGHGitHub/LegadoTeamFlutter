# legado-js 测试夹具

本目录为 `legado-js` 自持测试夹具。`songhe/` 于 2026-10-01 从
`legado-ffi/tests/fixtures/songhe/` 迁移/复制而来（P2 工程卫生：消除 `legado-js`
测试对 `legado-ffi` 测试夹具的跨 crate 路径引用，保证 legado-js 可独立移动/裁剪，
稀疏检出或仅检出 legado-js 时测试不挂；迁移模式参照 `legado-fetcher/tests/fixtures/README.md`）。

夹具均为**采集自真实站点的逐字数据**，请勿手改字节（含格式化）；如需更新请重新采集
并同步更新本文件中的 sha256。

## songhe 清单

| 文件 | 消费测试（`src/host_api/quickjs_impl.rs` 单元测试） | 来源与归属 |
|---|---|---|
| `detail.json` | `test_binding_songhe_detail_kind_no_zero_words` | 真实源「🏷松鹤庭沐·言璃」详情响应（curl 采集）；原位于 `legado-ffi/tests/fixtures/songhe/`，ffi 侧零引用，**迁移后已删除 ffi 副本**，本目录为唯一持有者 |
| `chapters.json` | `test_binding_songhe_chapters_no_free_lock` | 同名源目录页响应；原位于 `legado-ffi/tests/fixtures/songhe/`，ffi 侧零引用，**迁移后已删除 ffi 副本** |
| `search.json` | `test_binding_songhe_search_category` | 同名源真实搜索响应；**ffi 侧仍有引用**（`legado-ffi/examples/dbg_songhe_bookurl.rs` 默认读 `tests/fixtures/songhe/search.json`），故 ffi 保留原件、本目录留同源副本（双同步） |
| （`source.json`） | 本 crate 不消费 | 仍由 `legado-ffi/examples/dbg_songhe_{bookurl,explore,switch_break2}.rs` 使用，未迁移 |

sha256（2026-10-01 迁移时）：

```
16a6497d40e64dfbfa5ad88f632c0c70052ec86c9d6316702d9e66461c2d3357  chapters.json
4d32b1f120fb6e2ed2000049260fcdf835b4ac8b7bb3b81559766a88a69a52eb  detail.json
6a1a5cfa1c4af8dcb05da4758c9d192957cd41924b4336c9919d0dfd458e8bc5  search.json
```

## 双同步纪律

- `search.json` 为 legado-js 与 `legado-ffi` **双方持有**的同源副本：任何改动必须双处
  同步（本目录与 `legado-ffi/tests/fixtures/songhe/search.json`），并同步更新本文件
  sha256。
- `detail.json`、`chapters.json` ffi 侧已无引用并删除，legado-js 为唯一持有者；如未来
  ffi 需要复用，请从本目录复制一份自持副本，不要写跨 crate 相对路径。
- legado-js 测试只允许引用本 crate 目录内的夹具路径
  （`env!("CARGO_MANIFEST_DIR") + "/tests/fixtures/…"`）；由
  `quickjs_impl.rs::tests::test_songhe_fixtures_local_and_present` 守卫存在性与
  路径不得逃逸 crate 目录。新增跨 crate 反向引用一律禁止。
