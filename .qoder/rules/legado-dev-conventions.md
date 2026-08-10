# Legado 项目开发规范

本文件记录了项目开发过程中的约定、规范和最佳实践。

## 📊 优先级分类系统

UI修复和功能开发任务按以下优先级分类：

### P0 - 关键问题
- **定义**：阻塞性问题，影响核心功能或导致应用崩溃
- **处理**：必须立即修复，最高优先级
- **示例**：编译错误、运行时崩溃、核心功能失效

### P1 - 重要问题
- **定义**：影响用户体验但不阻塞使用的问题
- **处理**：在当前迭代中修复
- **示例**：UI布局错误、功能不完整、明显的视觉差异

### P2 - 次要问题
- **定义**：优化项，不影响功能但影响完美度
- **处理**：在资源允许时修复
- **示例**：动画效果、颜色微调、间距优化

### 应用场景
- 所有任务在开始前必须明确优先级
- 优先处理高优先级任务
- 避免在P2任务上投入过多时间而忽略P0/P1

## 🔍 验证优先工作流程

每次代码修改后必须执行验证步骤：

### 标准验证流程
1. **修改代码** - 使用 SearchReplace 或其他工具
2. **运行静态分析** - 执行 `flutter analyze`
3. **检查编译状态** - 确保无错误（warnings可接受）
4. **模拟器冒烟测试** - 执行 `.\scripts\emulator_smoke_test.ps1 -Device emulator-5556`（构建 APK → 安装 → 启动 → 进程/崩溃检查；UI 冒烟加 `-CheckUI`），退出码 0 才可继续
5. **查看变更** - 使用 `git diff` 确认修改内容
6. **提交或回滚** - 根据验证结果决定

### 验证失败处理
- 如果出现编译错误，立即修复或回滚
- 不要在已知有错误的代码基础上继续开发
- 记录错误信息以便后续分析

## 🔒 Git安全实践

### 文件恢复机制
当修改导致问题时，使用以下命令恢复：
```bash
git checkout HEAD -- <file_path>
```

### 安全原则
- **不要**在损坏的文件上继续工作
- **优先**恢复到已知良好状态
- **验证**恢复后文件是否正确

### 回滚时机
- 编译错误无法快速修复时
- 文件编码出现问题时
- 修改方向错误需要重新开始时

## 💻 Windows编码问题处理

### 已知问题
Windows环境下，中文字符在某些工具中可能出现编码问题：
- Git diff 显示乱码（如"无动画"显示为"无动?"）
- 某些终端工具无法正确显示中文注释

### 识别方法
- 运行 `git diff` 查看变更
- 如果中文显示为问号或乱码，说明存在编码问题
- 检查实际文件内容是否正确（使用 Read 工具）

### 解决方案
1. **确认文件内容** - 使用 Read 工具读取文件确认实际内容
2. **如果内容正确但显示错误** - 可以继续工作，这是显示问题
3. **如果内容也损坏** - 使用 `git checkout HEAD` 恢复文件
4. **考虑替代工具** - 如使用Python脚本进行文件修改

## 🛠️ 工具使用指南

### SearchReplace 工具
**优势**：
- 精确的文本替换
- 支持多行修改
- 自动显示变更diff

**限制**：
- Windows上可能存在UTF-8编码问题
- 对于包含中文的大规模修改可能不稳定

**最佳实践**：
- 用于小范围的精确修改
- 修改后立即验证
- 遇到问题及时回滚

### Python脚本替代方案
当SearchReplace遇到编码问题时，可以使用Python脚本：
```python
with open('file_path', 'r', encoding='utf-8') as f:
    content = f.read()

# 修改内容
content = content.replace('old', 'new')

with open('file_path', 'w', encoding='utf-8') as f:
    f.write(content)
```

## 📝 代码修改标准模式

### 枚举扩展模式
向枚举添加新值时，必须同步更新所有相关代码：

#### 步骤清单
1. ✅ 在枚举定义中添加新值
2. ✅ 更新所有switch语句，添加新case
3. ✅ 更新所有getter方法，处理新值
4. ✅ 更新相关UI代码，支持新值
5. ✅ 运行静态分析验证
6. ✅ 测试新功能

#### 示例：PageTurnMode枚举扩展
```dart
// 1. 添加枚举值
enum PageTurnMode {
  scroll,
  slide,
  simulate,
  none, // 新增
}

// 2. 更新displayName getter
String get displayName {
  switch (this) {
    case PageTurnMode.scroll:
      return '滚动';
    case PageTurnMode.slide:
      return '滑动';
    case PageTurnMode.simulate:
      return '仿真';
    case PageTurnMode.none: // 新增
      return '无动画';
  }
}

// 3. 更新icon getter
String get icon {
  switch (this) {
    case PageTurnMode.scroll:
      return '📜';
    case PageTurnMode.slide:
      return '👈';
    case PageTurnMode.simulate:
      return '📖';
    case PageTurnMode.none: // 新增
      return '⚡';
  }
}
```

### 检查清单
在提交枚举扩展前，确认：
- [ ] 枚举值已添加
- [ ] 所有switch语句已更新
- [ ] 所有getter已处理新值
- [ ] 静态分析无错误
- [ ] 相关UI已更新

## 🎯 工作习惯

### 增量式开发
- 小步修改，频繁验证
- 避免一次性大规模修改
- 每次修改聚焦单一问题

### 问题记录
- 遇到编码问题时立即记录
- 发现工具限制时及时更新文档
- 总结解决方案供后续参考

### 代码质量
- 遵循Dart编码规范
- 使用有意义的变量名和注释
- 保持代码简洁和可读性

## 📁 文档存放规范

### 统一存放位置
- 所有新建的计划、报告、交接、分析类 `.md` 文档必须创建在 `docs/` 文件夹内，不允许散落在项目根目录。
- 子项目（如 `rust/`、`flutter_legado/`）内部的文档仍保留在各自子项目目录下。

### 根目录例外
以下文件按社区惯例保留在项目根目录：
- `README.md`（项目说明）
- `CHANGELOG.md`（更新日志）
- `LICENSE`（许可证）
- `AGENTS.md`（Agent 工作入口）

### 现有文档
根目录原有的过程/报告类文档（UI_FIX 系列、KOTLIN 系列、REFACTORING_FIX_REPORT.md、TASK_76_SUMMARY.md、VERSION_CONTROL.md、DEVELOPMENT.md、api.md 等）已统一迁移至 `docs/`，详见 [docs/README.md](../../docs/README.md) 索引。

## 📚 参考资源

- [Dart语言指南](https://dart.dev/guides/language)
- [Flutter开发文档](https://flutter.dev/docs)
- [Git官方文档](https://git-scm.com/doc)

---

**最后更新**: 2024年
**维护者**: Legado开发团队
