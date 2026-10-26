//! Server Repository - servers 表 CRUD（对齐原版 Room `ServerDao`）
//!
//! 数据模型复用 [`legado_core::models::Server`]（serde 键 `id`/`name`/`type`/
//! `config`/`sortNumber`，与原版 Gson 序列化同名），本仓储为 servers 表
//! **唯一**读写实现：FFI `webdavServersList`/`webdavServerSave`/
//! `webdavServerDelete` 与备份收集/恢复全部委托本仓储（防复发规定 1）。

use rusqlite::{params, Connection, OptionalExtension};

use legado_core::models::{Server, ServerType};
use legado_core::{LegadoError, LegadoResult};

/// 查询列（与 [`row_to_server`] 的列索引一一对应）
const SELECT_COLUMNS: &str = "SELECT id, name, type, config, sortNumber FROM servers";

/// 默认 WebDAV 同步服务器主键
///
/// 对齐原版 `AppConst.DEFAULT_WEBDAV_ID = -1L`：负数主键表示「默认 WebDAV
/// 同步账号」而非用户自建远程书库服务器；`webdavServerSave` 对负数 id
/// 原样保留（仅 id = 0 视为未分配）。
pub const DEFAULT_WEBDAV_SERVER_ID: i64 = -1;

/// 默认 WebDAV 同步服务器显示名（迁移时写入，用户可在后续批次改名）
pub const DEFAULT_WEBDAV_SERVER_NAME: &str = "默认 WebDAV";

/// servers 数据访问层
pub struct ServerRepository<'a> {
    conn: &'a Connection,
}

impl<'a> ServerRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 获取全部服务器（对齐原版 `ServerDao.all`：`order by sortNumber`）
    ///
    /// `sortNumber` 相同时按 `id` 升序，保证输出稳定（SQLite 未定义同值顺序）。
    pub fn find_all(&self) -> LegadoResult<Vec<Server>> {
        let mut stmt = self
            .conn
            .prepare(&format!("{SELECT_COLUMNS} ORDER BY sortNumber, id"))
            .map_err(|e| LegadoError::Database(format!("准备查询服务器失败: {e}")))?;
        let rows = stmt
            .query_map([], row_to_server)
            .map_err(|e| LegadoError::Database(format!("查询服务器失败: {e}")))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| LegadoError::Database(format!("读取服务器行失败: {e}")))?;
        Ok(rows)
    }

    /// 按主键查询
    pub fn find_by_id(&self, id: i64) -> LegadoResult<Option<Server>> {
        let mut stmt = self
            .conn
            .prepare(&format!("{SELECT_COLUMNS} WHERE id = ?1"))
            .map_err(|e| LegadoError::Database(format!("准备查询服务器失败: {e}")))?;
        stmt.query_row(params![id], row_to_server)
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询服务器失败: {e}")))
    }

    /// 全字段 upsert（`INSERT OR REPLACE`，对齐原版 `ServerDao.insert` 的 REPLACE）
    ///
    /// 主键语义：
    /// - `id > 0`：原样写入（用户自建服务器，原版默认 `System.currentTimeMillis()`）；
    /// - `id < 0`：原样写入（`-1` = 默认 WebDAV 同步账号固定身份）；
    /// - `id == 0`：按当前毫秒分配并避让既有主键（对齐原版构造默认值语义）。
    ///
    /// 返回实际落库 id。
    pub fn upsert(&self, server: &Server) -> LegadoResult<i64> {
        let id = if server.id == 0 {
            self.next_generated_id()?
        } else {
            server.id
        };
        let type_str = server_type_to_db(&server.server_type)?;
        self.conn
            .execute(
                "INSERT OR REPLACE INTO servers (id, name, type, config, sortNumber)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![id, server.name, type_str, server.config, server.sort_number,],
            )
            .map_err(|e| LegadoError::Database(format!("写入服务器失败: {e}")))?;
        Ok(id)
    }

    /// 按 id 删除，返回是否命中行（对齐原版 `ServerDao.delete(id)` 静默语义）
    pub fn delete(&self, id: i64) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute("DELETE FROM servers WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除服务器失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 生成新主键：当前毫秒，冲突时递增避让
    fn next_generated_id(&self) -> LegadoResult<i64> {
        let now = current_time_millis();
        let mut candidate = now;
        loop {
            if self.find_by_id(candidate)?.is_none() {
                return Ok(candidate);
            }
            candidate += 1;
        }
    }
}

fn server_type_to_db(server_type: &ServerType) -> LegadoResult<String> {
    serde_json::to_value(server_type)
        .ok()
        .and_then(|v| v.as_str().map(str::to_string))
        .ok_or_else(|| LegadoError::Database("servers.type 序列化失败".into()))
}

/// 读取 `type` 列：未知枚举值显式报错（防复发规定 4，禁止静默回落 WEBDAV）
fn server_type_from_db(raw: &str) -> LegadoResult<ServerType> {
    serde_json::from_value::<ServerType>(serde_json::Value::String(raw.to_string()))
        .map_err(|e| LegadoError::Database(format!("servers.type 形态不符（{raw}）: {e}")))
}

fn row_to_server(row: &rusqlite::Row<'_>) -> rusqlite::Result<Server> {
    let type_raw: String = row.get(2)?;
    // 类型解析失败经 rusqlite 错误通道上抛；调用方统一映射为 Database 错误
    let server_type = server_type_from_db(&type_raw).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(2, rusqlite::types::Type::Text, Box::new(e))
    })?;
    Ok(Server {
        id: row.get(0)?,
        name: row.get(1)?,
        server_type,
        config: row.get(3)?,
        sort_number: row.get(4)?,
    })
}

fn current_time_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full_server() -> Server {
        Server {
            id: -1,
            name: DEFAULT_WEBDAV_SERVER_NAME.to_string(),
            server_type: ServerType::WebDav,
            config: Some(
                r#"{"url":"https://dav.example.com/","username":"u","password":"p"}"#.to_string(),
            ),
            sort_number: 3,
        }
    }

    /// 全字段写入/读回（含负数主键原样保留）
    #[test]
    fn test_upsert_and_find_roundtrip() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ServerRepository::new(db.connection());
        let seed = full_server();
        let id = repo.upsert(&seed).unwrap();
        assert_eq!(id, -1, "负数主键应原样保留（默认 WebDAV 固定身份）");

        let found = repo.find_by_id(-1).unwrap().unwrap();
        assert_eq!(found.name, DEFAULT_WEBDAV_SERVER_NAME);
        assert_eq!(found.server_type, ServerType::WebDav);
        assert_eq!(found.config, seed.config);
        assert_eq!(found.sort_number, 3);
    }

    /// id = 0 分配当前毫秒主键；同 id 重复写入为整行替换
    #[test]
    fn test_upsert_assigns_id_when_zero_and_replaces() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ServerRepository::new(db.connection());
        let mut server = Server {
            name: "新建".to_string(),
            server_type: ServerType::WebDav,
            ..Default::default()
        };
        server.id = 0;
        let id = repo.upsert(&server).unwrap();
        assert!(id > 0, "id = 0 应分配正数主键");

        server.id = id;
        server.name = "改名".to_string();
        repo.upsert(&server).unwrap();
        assert_eq!(repo.find_all().unwrap().len(), 1, "同 id 应整行替换");
        assert_eq!(repo.find_by_id(id).unwrap().unwrap().name, "改名");
    }

    /// find_all 按 sortNumber 升序（对齐原版 order by sortNumber）
    #[test]
    fn test_find_all_ordered_by_sort_number() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ServerRepository::new(db.connection());
        for (id, sort_number) in [(1, 20), (2, 5), (3, 10)] {
            repo.upsert(&Server {
                id,
                name: format!("服务器{id}"),
                server_type: ServerType::WebDav,
                config: None,
                sort_number,
            })
            .unwrap();
        }
        let ids: Vec<i64> = repo.find_all().unwrap().iter().map(|s| s.id).collect();
        assert_eq!(ids, vec![2, 3, 1]);
    }

    /// 删除：命中返回 true，不存在返回 false（不抛错）
    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ServerRepository::new(db.connection());
        repo.upsert(&full_server()).unwrap();
        assert!(repo.delete(-1).unwrap());
        assert!(!repo.delete(-1).unwrap());
        assert!(repo.find_all().unwrap().is_empty());
    }

    /// 未知 type 列形态显式报错（不静默回落 WEBDAV）
    #[test]
    fn test_unknown_type_is_explicit_error() {
        let db = crate::init_in_memory_database().unwrap();
        db.connection()
            .execute(
                "INSERT INTO servers (id, name, type, config, sortNumber)
                 VALUES (9, '未知', 'FTP', NULL, 0)",
                [],
            )
            .unwrap();
        let err = ServerRepository::new(db.connection())
            .find_by_id(9)
            .expect_err("未知 type 应报错");
        assert!(
            matches!(err, LegadoError::Database(_)),
            "应为 Database 错误，实际: {err:?}"
        );
    }
}
