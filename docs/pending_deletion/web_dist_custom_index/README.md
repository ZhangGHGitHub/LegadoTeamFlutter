# 待删除：自制 Web 首页（web-dist_custom_index）

## 来源与移出原因

- 文件来源：`rust/legado-server/web-dist/index.html`（9,536 字节，自制单页）
- 移出日期：2026-10-06
- 依据：B1 批次要求「Web 服务页面与原版一致」——原版前端资产
  （`app/src/main/assets/web/**`，67 文件 / 2,065,667 字节）已整目录拷入
  `rust/legado-server/web-dist/` 并以编译期嵌入方式提供；原自制首页与该目录下
  同名 `index.html` 冲突，按项目既有约定先移入待删除目录，不直接删除。
- 相关报告：`docs/WEB_UI_PARITY_SURVEY_20261007.md`（§四 落点选择）
- 用户裁决（2026-10-06）：Web 服务书架页面（浏览器页面）必须与原版一致；
  自制页不再作为 `/` 的响应内容。

## 后续处置

- 观察期无问题后，下一批清理时 `git rm` 本目录整体删除。
- 删除前确认：`rust/legado-server/web-dist/index.html` 已存在且为原版导航页
  （含 `<title>Legado web 导航</title>`），`cargo test -p legado-server` 通过。
