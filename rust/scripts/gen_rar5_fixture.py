"""构造最小 RAR5 归档（单文件 STORE 无压缩），输出 Rust 字节字面量"""
import zlib
import struct


def vint(n: int) -> bytes:
    """RAR5 变长整数：base-128 little-endian，高位为续传标志"""
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def block(header_type: int, flags: int, body: bytes, data_size: int | None = None) -> bytes:
    """通用块：CRC32 + vint(HeaderSize) + vint(type) + vint(flags) [+ vint(DataSize)] + body"""
    head = vint(header_type) + vint(flags)
    if flags & 0x0002:  # Data area 存在 → DataSize 紧随 flags
        head += vint(data_size)
    header_body = head + body
    payload = vint(len(header_body)) + header_body
    crc = zlib.crc32(payload) & 0xFFFFFFFF
    return struct.pack("<I", crc) + payload


def main() -> None:
    sig = b"Rar!\x1a\x07\x01\x00"

    # 主归档头（type=1，flags=0，archive flags=0）
    main_hdr = block(1, 0, vint(0))

    # 文件头（type=2）
    content = b"Hello RAR World!"
    name = b"hello.txt"
    file_flags = 0x0004  # CRC present
    body = b"".join([
        vint(file_flags),          # File flags
        vint(len(content)),        # Unpack size
        vint(0x20),                # Attributes (archive)
        struct.pack("<I", zlib.crc32(content) & 0xFFFFFFFF),  # Data CRC32
        vint(0),                   # Compression info: version0/solid0/method0(store)
        vint(1),                   # Host OS: Unix
        vint(len(name)) + name,    # Name
    ])
    file_hdr = block(2, 0x0002, body, data_size=len(content)) + content

    # 归档结束块（type=5，endarc flags=0）
    end_hdr = block(5, 0, vint(0))

    data = sig + main_hdr + file_hdr + end_hdr
    rust = ", ".join(f"0x{b:02x}" for b in data)
    print(f"// 共 {len(data)} 字节")
    print(f"const RAR5_HELLO: &[u8] = &[{rust}];")


if __name__ == "__main__":
    main()
