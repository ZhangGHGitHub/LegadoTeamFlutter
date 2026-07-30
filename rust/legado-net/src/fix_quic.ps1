$content = Get-Content -Path "quic.rs" -Raw

$old = @'
    /// 内部清理连接池
    async fn cleanup_pool_internal(&self, pool: &mut HashMap<String, PoolEntry>) {
        pool.retain(|_, entry| {
            let keep = entry.last_used.elapsed() < self.config.idle_timeout
                && pool.len() <= self.config.max_idle_connections;
            if !keep {
                log::debug!("移除过期连接");
            }
            keep
        });
    }
'@

$new = @'
    /// 内部清理连接池
    async fn cleanup_pool_internal(&self, pool: &mut HashMap<String, PoolEntry>) {
        let idle_timeout = self.config.idle_timeout;
        let max_connections = self.config.max_idle_connections;
        
        // 先移除过期的连接
        pool.retain(|_, entry| {
            let keep = entry.last_used.elapsed() < idle_timeout;
            if !keep {
                log::debug!("移除过期连接");
            }
            keep
        });
        
        // 如果连接数超过限制，移除最旧的连接
        while pool.len() > max_connections {
            if let Some(oldest_key) = pool.iter()
                .min_by_key(|(_, entry)| entry.last_used)
                .map(|(k, _)| k.clone()) {
                pool.remove(&oldest_key);
                log::debug!("移除最旧连接以限制连接池大小");
            } else {
                break;
            }
        }
    }
'@

$content = $content -replace [regex]::Escape($old), $new
Set-Content -Path "quic.rs" -Value $content -NoNewline -Encoding UTF8
Write-Output "Fixed cleanup_pool_internal"
