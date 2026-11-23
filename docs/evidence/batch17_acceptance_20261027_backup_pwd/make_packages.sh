#!/usr/bin/env bash
# 批17 加密备份恢复设备验收：测试包构造
# 加密：宿主 openssl AES-128-ECB/PKCS7（等价 PKCS5）；打包：Python zipfile（标准 zip）
# 密钥：MD5(password) 小写 hex 前 16 个 ASCII 字符（不做 hex 解码）
set -euo pipefail
cd "$(dirname "$0")"

key_ascii() { printf '%s' "$1" | md5sum | cut -c1-16; }
key_hex()   { key_ascii "$1" | tr -d '[:space:]' | od -An -v -tx1 | tr -d '[:space:]'; }

enc_b64() { # $1=input file, $2=password, $3=output file
  openssl enc -aes-128-ecb -K "$(key_hex "$2")" -nosalt -in "$1" -out "$3" -a -A
}

zip_pkg() { # $1=output zip, 其余为 "src:dest"
  python make_zip.py "$@"
}

: > openssl_commands.log
{
  echo "=== 密钥派生（MD5 小写 hex 前 16 个 ASCII 字符）==="
  echo "空密码 key = $(key_ascii '')  -> bytes hex $(key_hex '')"
  echo "secret  key = $(key_ascii 'secret')  -> bytes hex $(key_hex 'secret')"
  echo
  echo "=== openssl 加密命令 ==="
} >> openssl_commands.log

# 包 A：空密码加密 servers.json（+ 明文 bookSource.json）
enc_b64 plain/servers_accept.json '' packages/servers_A.json.b64
echo "openssl enc -aes-128-ecb -K $(key_hex '') -nosalt -in plain/servers_accept.json -out packages/servers_A.json.b64 -a -A" >> openssl_commands.log
zip_pkg packages/backup_accept_A.zip "packages/servers_A.json.b64:servers.json" "plain/bookSource_accept.json:bookSource.json"

# 包 B：secret 加密 servers/cookies/runtimeSourceCache（+ 明文 bookSource.json）
enc_b64 plain/servers_accept.json 'secret' packages/servers_B.json.b64
enc_b64 plain/cookies_accept.json 'secret' packages/cookies_B.json.b64
enc_b64 plain/runtime_accept.json 'secret' packages/runtime_B.json.b64
for f in servers cookies runtime; do
  echo "openssl enc -aes-128-ecb -K $(key_hex 'secret') -nosalt -in plain/${f}_accept.json -out packages/${f}_B.json.b64 -a -A" >> openssl_commands.log
done
zip_pkg packages/backup_accept_B.zip "packages/servers_B.json.b64:servers.json" "packages/cookies_B.json.b64:cookies.json" "packages/runtime_B.json.b64:runtimeSourceCache.json" "plain/bookSource_accept.json:bookSource.json"

# 包 C：损坏——servers.json 为 secret 密文截断（前 40 个 base64 字符）
head -c 40 packages/servers_B.json.b64 > packages/servers_C_truncated.b64
zip_pkg packages/backup_accept_C.zip "packages/servers_C_truncated.b64:servers.json"
echo "head -c 40 packages/servers_B.json.b64 > packages/servers_C_truncated.b64  # 包 C 截断密文" >> openssl_commands.log
echo "zip: python zipfile ZIP_DEFLATED -> packages/backup_accept_A.zip/_B.zip/_C.zip" >> openssl_commands.log

echo "=== 生成文件 ==="
ls -l packages/
echo "=== 密文预览 ==="
for f in packages/servers_A.json.b64 packages/servers_B.json.b64 packages/cookies_B.json.b64 packages/runtime_B.json.b64 packages/servers_C_truncated.b64; do
  echo "--- $f ($(wc -c < "$f") bytes)"
  cat "$f"
  echo
done
echo "=== zip 内容 ==="
python list_zip.py
