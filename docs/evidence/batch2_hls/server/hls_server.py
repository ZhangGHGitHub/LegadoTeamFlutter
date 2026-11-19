#!/usr/bin/env python3
"""批 2 HLS 音频缓存验收用的本地回环 HLS 服务（只读、无状态）。

端点：
  /master.m3u8       master：独立音频轨（URI=/audio.m3u8，无 CODECS）+ 两个视频档（CODECS 含 avc1）
  /master-nocodes.m3u8  master：只有 variant，音频档省略 CODECS（无 EXT-X-MEDIA），验证选档回落
  /audio.m3u8        音频 media playlist：3 段 + EXT-X-ENDLIST
  /video.m3u8        视频 media playlist：3 段 + EXT-X-ENDLIST
  /seg0.ts /seg1.ts /seg2.ts   真实 AAC-in-TS 分片（ffmpeg 生成，各约 5-10KB）
  /live.m3u8         无 EXT-X-ENDLIST（直播 → 应拒绝）
  /empty-seg.m3u8    第 2 段 0 字节（空分片 → 应拒绝）
  /empty-seg0.ts /empty-seg1.ts(0B) /empty-seg2.ts
  /auth/master.m3u8  同站/跨站头门控 master：音频档在 /auth/（同站），分片分别在
                     /auth/（同站）与 /xsite/（跨站）
  /auth/audio.m3u8   同站 media playlist
  /xsite/audio.m3u8  跨站 media playlist

请求日志 JSONL 落到 HLS_LOG（默认 requests.jsonl），记录 Authorization/Cookie/
Referer/UA，用于逐条核对「实际下载了哪个档」「哪个站收到了什么头」。
"""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_PATH = os.environ.get("HLS_LOG", "requests.jsonl")
PORT = int(os.environ.get("HLS_PORT", "18080"))
MEDIA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "media")
# 「跨站」基址：与同站基址不同 host 即跨站（域名键不同）。默认宿主 LAN IP。
XSITE_BASE = os.environ.get("HLS_XSITE_BASE", "http://192.168.100.52:18080")

M3U8 = "application/vnd.apple.mpegurl"


def read_media(name):
    with open(os.path.join(MEDIA_DIR, name), "rb") as f:
        return f.read()


MASTER = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,URI="/audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2500000,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud"
/video.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.42e01e"
/video.m3u8
"""

# 无 EXT-X-MEDIA 的纯 variant 形态：音频档故意省略 CODECS，视频档带 avc1
MASTER_NOCODECS = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1920x1080,CODECS="avc1.4d401f,mp4a.40.2"
/video.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=128000
/audio.m3u8
"""

AUDIO_MEDIA = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:3
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:2.0,
/seg0.ts
#EXTINF:2.0,
/seg1.ts
#EXTINF:2.0,
/seg2.ts
#EXT-X-ENDLIST
"""

VIDEO_MEDIA = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:3
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:2.0,
/seg0.ts
#EXTINF:2.0,
/seg1.ts
#EXTINF:2.0,
/seg2.ts
#EXT-X-ENDLIST
"""

LIVE_MEDIA = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:3
#EXT-X-MEDIA-SEQUENCE:100
#EXTINF:2.0,
/seg0.ts
#EXTINF:2.0,
/seg1.ts
#EXTINF:2.0,
/seg2.ts
"""

EMPTY_MEDIA = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:3
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:2.0,
/empty-seg0.ts
#EXTINF:2.0,
/empty-seg1.ts
#EXTINF:2.0,
/empty-seg2.ts
#EXT-X-ENDLIST
"""

# 头门控：音频档与首个分片同站（相对路径 → 解析到源站 host），
# 第二个分片用绝对 URL 指向 127.0.0.1（与源站 host 不同 → 跨站）
AUTH_MASTER = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,URI="/auth/audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2500000,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud"
/auth/video.m3u8
"""

AUTH_MEDIA_TMPL = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:3
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:2.0,
/auth/seg0.ts
#EXTINF:2.0,
{xsite}/xsite/seg1.ts
#EXT-X-ENDLIST
"""

AUTH_VIDEO_MEDIA = AUTH_MEDIA_TMPL


def log_request(path, headers):
    rec = {
        "ts": round(time.time(), 3),
        "path": path,
        "headers": {
            k: v for k, v in headers.items()
            if k.lower() in ("authorization", "cookie", "referer", "user-agent",
                             "proxy-authorization", "x-play-option")
        },
    }
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        log_request(self.path, dict(self.headers))

        # probe：回放已记录的请求（设备侧测试可直接断言头门控，证据自包含）
        if path == "/probe/requests":
            try:
                with open(LOG_PATH, "r", encoding="utf-8") as f:
                    recs = [json.loads(line) for line in f if line.strip()]
            except FileNotFoundError:
                recs = []
            # 排除 probe 自身
            recs = [r for r in recs if not r["path"].startswith("/probe/")]
            return self._send(200, json.dumps(recs, ensure_ascii=False), "application/json")

        # 清空日志（设备侧测试在场景前调用，隔离证据窗口）
        if path == "/probe/reset":
            open(LOG_PATH, "w", encoding="utf-8").close()
            return self._send(200, '{"reset":true}', "application/json")

        playlists = {
            "/master.m3u8": MASTER,
            "/master-nocodes.m3u8": MASTER_NOCODECS,
            "/audio.m3u8": AUDIO_MEDIA,
            "/video.m3u8": VIDEO_MEDIA,
            "/live.m3u8": LIVE_MEDIA,
            "/empty-seg.m3u8": EMPTY_MEDIA,
            "/auth/master.m3u8": AUTH_MASTER,
            "/auth/audio.m3u8": AUTH_MEDIA_TMPL.format(xsite=XSITE_BASE),
            "/auth/video.m3u8": AUTH_VIDEO_MEDIA.format(xsite=XSITE_BASE),
            "/xsite/audio.m3u8": AUTH_MEDIA_TMPL.format(xsite=XSITE_BASE),
        }
        if path in playlists:
            return self._send(200, playlists[path], M3U8)

        seg_names = {
            "/seg0.ts": "seg0.ts",
            "/seg1.ts": "seg1.ts",
            "/seg2.ts": "seg2.ts",
            "/empty-seg0.ts": "seg0.ts",
            "/empty-seg1.ts": None,          # 空分片
            "/empty-seg2.ts": "seg2.ts",
            "/auth/seg0.ts": "seg0.ts",
            "/auth/seg1.ts": "seg1.ts",
            "/xsite/seg1.ts": "seg1.ts",
        }
        if path in seg_names:
            name = seg_names[path]
            body = b"" if name is None else read_media(name)
            return self._send(200, body, "video/mp2t")

        return self._send(404, "not found", "text/plain")


def main():
    open(LOG_PATH, "w", encoding="utf-8").close()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"listening on 0.0.0.0:{PORT}, log={LOG_PATH}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
