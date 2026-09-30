# 待删除素材暂存（pending deletion）

本目录存放已移出正式资源目录、等待最终删除的素材文件。

## 当前内容

- `assets_icons_unused/`：`flutter_legado/assets/icons/ic_bottom_*.svg` 共 8 个底部导航图标
  - 移出日期：2026-09-30
  - 依据：全仓（lib/ + test/）零引用（调研报告 `docs/LOADING_ASSETS_UNIFY_SURVEY_20260930.md` §3 终核 grep=0），疑似早期底部导航方案的遗留素材
  - 用户裁决（2026-09-30）：先移动到待删除目录，暂不直接删除
  - 后续处置：观察期无问题后，下一批清理时 `git rm` 本目录整体删除；删除前建议再跑一次全仓 grep 终核
- 同步改动：`flutter_legado/pubspec.yaml` 已移除 `- assets/icons/` 声明（目录已空，保留声明会导致构建报错）

> 注意：本目录位于 `docs/` 下、不在 pubspec assets 声明内，不会打进应用包。
