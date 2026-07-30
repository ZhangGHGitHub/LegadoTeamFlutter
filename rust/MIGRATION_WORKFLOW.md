## 数据库 Schema 迁移开发流程

当需要修改 `schema.rs`（新增/删除列、新增表）时，必须严格遵循以下步骤：

### 1. 自动生成 Migration 代码

修改 `schema.rs` 后，同步创建新的 Migration：

```bash
# 在 rust/legado-db/src/migration/migrations.rs 中添加新的迁移结构体
# 命名规范：Migration{from}To{to}，如 Migration95To96

# 步骤：
# 1. 创建 pub struct Migration95To96;
# 2. 实现 Migration trait（from_version, to_version, description, up, down）
# 3. 在 up() 中使用 add_column_if_not_exists() 添加新列
# 4. 在 migration.rs 的 register_defaults() 中注册新迁移
# 5. 更新 schema.rs 的 SCHEMA_VERSION 常量
```

### 2. CI/CD 验证版本一致性

在 CI pipeline 中添加验证步骤，确保 `SCHEMA_VERSION` 与 `migrations.rs` 中的最高版本一致：

```bash
# 验证脚本示例（添加到 .github/workflows/rust-ci.yml）
- name: Verify schema version consistency
  run: |
    SCHEMA_VER=$(grep -oP 'SCHEMA_VERSION: u32 = \K\d+' rust/legado-db/src/schema.rs)
    MIGRATION_VER=$(grep -oP 'fn to_version.*\{.*\n.*\K\d+' rust/legado-db/src/migration/migrations.rs | tail -1)
    if [ "$SCHEMA_VER" != "$MIGRATION_VER" ]; then
      echo "ERROR: SCHEMA_VERSION ($SCHEMA_VER) != latest migration version ($MIGRATION_VER)"
      exit 1
    fi
    echo "Schema version check passed: v$SCHEMA_VER"
```

### 3. 数据库测试覆盖新旧版本迁移

为每个新 Migration 添加测试用例，覆盖以下场景：

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_migration_95_to_96_adds_columns() {
        // 1. 创建 v95 版本的数据库（缺少新列）
        let db = create_db_at_version(95);
        let conn = db.connection();
        
        // 2. 验证新列不存在
        assert!(!column_exists(conn, "books", "infoHtml"));
        
        // 3. 执行迁移
        let registry = MigrationRegistry::new();
        registry.migrate_to(conn, 96, 95).unwrap();
        
        // 4. 验证版本号更新
        assert_eq!(MigrationRegistry::current_version(conn).unwrap(), 96);
        
        // 5. 验证新列已存在
        assert!(column_exists(conn, "books", "infoHtml"));
        assert!(column_exists(conn, "books", "tocHtml"));
        assert!(column_exists(conn, "books", "downloadUrls"));
        assert!(column_exists(conn, "books", "coverOrigin"));
    }
}
```

### 检查清单

修改 schema 前确认：
- [ ] schema.rs 已更新 CREATE TABLE 语句
- [ ] migration/migrations.rs 已添加新的 Migration 结构体
- [ ] migration.rs 的 register_defaults() 已注册新迁移
- [ ] schema.rs 的 SCHEMA_VERSION 已递增
- [ ] 已添加测试用例覆盖迁移场景
- [ ] CI/CD 验证通过
