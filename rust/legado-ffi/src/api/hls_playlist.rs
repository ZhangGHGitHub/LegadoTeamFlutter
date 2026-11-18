//! HLS（m3u8）播放列表解析（批 2 线 A）
//!
//! 纯解析模块：**不做任何网络请求**，只把 m3u8 文本转成结构化模型，供
//! 上层（缓存/播放/预下载）消费。零新增 crate——相对路径绝对化复用
//! [`legado_parser::AnalyzeUrl::get_absolute_url`]（与原版
//! `NetworkUtils.getAbsoluteURL` 同语义）。
//!
//! # 支持范围（RFC 8216）
//!
//! | 标签 | 语义 |
//! |---|---|
//! | `#EXTM3U` | 首行必需（BOM 自动剥除） |
//! | `#EXT-X-STREAM-INF` | master playlist 的 variant（`BANDWIDTH` / `CODECS` / `RESOLUTION` / `AUDIO`） |
//! | `#EXT-X-MEDIA` | `TYPE=AUDIO` 的独立音频轨（`GROUP-ID` / `NAME` / `URI` / `DEFAULT`） |
//! | `#EXTINF` | media playlist 的段时长（标题丢弃） |
//! | `#EXT-X-KEY` | `METHOD=AES-128` 支持；`METHOD=NONE` 表示不加密 |
//! | `#EXT-X-MAP` | fMP4 初始化段（**至多一个**；多个视为多 period，显式报错） |
//! | `#EXT-X-BYTERANGE` | 同文件字节区间（`n[@o]`，缺省 offset 按 §4.3.2.2 续接） |
//! | `#EXT-X-DISCONTINUITY` | 段边界标记（仅落到 [`Segment::discontinuity`]；**不做** init map 重放） |
//! | `#EXT-X-MEDIA-SEQUENCE` | IV 缺省时的序列号基准（§5.2） |
//! | `#EXT-X-ENDLIST` | 点播（非直播）标记；见 [`MediaPlaylist::is_vod`] |
//!
//! **显式报错（不静默降级）**：`METHOD=SAMPLE-AES*`（含 SAMPLE-AES-CTR）、
//! `#EXT-X-I-FRAMES-ONLY`、其它未知加密方法、以及**多个 `#EXT-X-MAP`**
//! （多 period fMP4——单一 init map 无法覆盖全部分片，静默取最后一个会把
//! 前段拼到错误 init 上，产物不可播且无报错）。
//!
//! # 直播（live）playlist
//!
//! 无 `#EXT-X-ENDLIST` 的 playlist 只是**当前滑动窗口**的快照，按窗口下载会
//! 得到「半章」。调用方必须先用 [`MediaPlaylist::is_vod`] 判定，`false` 时
//! 拒绝缓存（本模块只解析，不做该判定）。
//!
//! # 容错口径
//!
//! - 未知标签（`#EXT-X-VERSION`/`#EXT-X-TARGETDURATION`/`#EXT-X-MEDIA`/
//!   `#EXT-X-DATERANGE` 等）**忽略**；
//! - 空行与 `#` 注释行忽略；行尾 `\r` 与首部 BOM 剥除；
//! - 已知标签的值畸形（`EXTINF` 非数字、`BYTERANGE` 非数字、`IV` 非十六进制、
//!   `EXT-X-KEY` 缺 `METHOD`/`URI`）→ `LegadoError::Parser`；
//! - 只有 `#EXTM3U` 的 playlist 是**合法但空**的 media playlist（0 段），
//!   由上层决定是否可用；空文本/无 `#EXTM3U` 首行 → Err。
//!
//! # 缺省值处理
//!
//! 1. **IV 缺省**（§5.2）：`IV` 属性缺失时，用「媒体序列号」= `EXT-X-MEDIA-SEQUENCE`
//!    起始值 + 该段在 playlist 中的下标（0 起），按 128-bit 大端填入。因此解析结果里
//!    每个 AES-128 段的 `HlsKey.iv` **恒为 `Some`**，下游无需再算。
//! 2. **BYTERANGE 缺省 offset**（§4.3.2.2）：紧接**同一 URI** 上一段的末尾
//!    （`offset + length`）；无同 URI 前驱则回落到 0。`EXT-X-MAP` 的 `BYTERANGE`
//!    缺省 offset 取 0（初始化段独立资源，不与媒体段共享区间）。
//! 3. **KEY 继承**：`#EXT-X-KEY` 对其后所有段生效，直到下一个 `#EXT-X-KEY`
//!    （`METHOD=NONE` 显式终止继承）。

use legado_core::{LegadoError, LegadoResult};
use legado_parser::AnalyzeUrl;

/// master playlist（多码率/多编码档位）
#[derive(Debug, Clone, PartialEq)]
pub struct MasterPlaylist {
    pub variants: Vec<Variant>,
    /// `#EXT-X-MEDIA:TYPE=AUDIO` 声明的独立音频轨（按出现顺序）
    pub audio_groups: Vec<AudioRendition>,
}

/// master playlist 的一个档位
#[derive(Debug, Clone, PartialEq)]
pub struct Variant {
    /// `BANDWIDTH` 属性（bit/s）
    pub bandwidth: u64,
    /// `CODECS` 属性原文（可能含逗号，如 `"avc1.4d401f,mp4a.40.2"`）；缺失为 `None`
    pub codecs: Option<String>,
    /// `RESOLUTION` 属性（宽, 高）；存在即**强信号**表明该档含视频
    pub resolution: Option<(u32, u32)>,
    /// `AUDIO` 属性引用的 `#EXT-X-MEDIA` 音频组 ID
    pub audio_group: Option<String>,
    /// 档位播放列表 URI（已绝对化）
    pub uri: String,
}

impl Variant {
    /// 是否明确含视频轨
    ///
    /// 判定依据（任一成立即为视频档）：
    /// - 有 `RESOLUTION`（纯音频档不会声明分辨率）；
    /// - `CODECS` 含视频编码标识（`avc1`/`hvc1`/`hev1`/`av01`/`vp09`/`vp08`/
    ///   `dvh1`/`dvhe`/`dva1`/`dvav`，大小写不敏感）。
    pub fn has_video(&self) -> bool {
        self.resolution.is_some() || self.codecs.as_deref().is_some_and(has_video_codec)
    }

    /// 是否「明确纯音频」：无 `RESOLUTION` 且 `CODECS` 存在但只列音频编码
    pub fn is_audio_only(&self) -> bool {
        if self.resolution.is_some() {
            return false;
        }
        match self.codecs.as_deref().map(str::trim) {
            Some(codecs) if !codecs.is_empty() => !has_video_codec(codecs),
            // CODECS 缺失/为空：信息不足，不算「明确纯音频」
            _ => false,
        }
    }

    /// 是否「无任何视频信号」：无 `RESOLUTION` 且 `CODECS` 未标明视频编码
    ///
    /// 这是比 [`Self::is_audio_only`] 更宽的判据：`CODECS` 完全缺失的档位也
    /// 满足（真实世界里纯音频档常常省略 `CODECS`）。
    pub fn lacks_video_signal(&self) -> bool {
        !self.has_video()
    }
}

/// `#EXT-X-MEDIA:TYPE=AUDIO` 声明的独立音频轨
#[derive(Debug, Clone, PartialEq)]
pub struct AudioRendition {
    /// `GROUP-ID` 属性
    pub group_id: String,
    /// `NAME` 属性（人可读名）
    pub name: Option<String>,
    /// `LANGUAGE` 属性
    pub language: Option<String>,
    /// `DEFAULT=YES`
    pub default: bool,
    /// `URI` 属性（已绝对化）；缺失表示该音轨复用档位内的音频
    pub uri: Option<String>,
}

/// 视频编码标识（`CODECS` 中出现的即视为视频档）
const VIDEO_CODEC_PREFIXES: &[&str] = &[
    "avc1", // H.264/AVC
    "avc3", // H.264/AVC（带内参数集）
    "hvc1", // H.265/HEVC
    "hev1", // H.265/HEVC（带内参数集）
    "av01", // AV1
    "vp09", // VP9
    "vp08", // VP8
    "dvh1", // Dolby Vision（HEVC 基础）
    "dvhe", // Dolby Vision（HEVC 基础，旧标识）
    "dva1", // Dolby Vision（AVC 基础）
    "dvav", // Dolby Vision（AVC 基础，旧标识）
];

/// `CODECS` 原文是否含视频编码标识（大小写不敏感）
fn has_video_codec(codecs: &str) -> bool {
    let lower = codecs.to_ascii_lowercase();
    VIDEO_CODEC_PREFIXES
        .iter()
        .any(|prefix| lower.contains(prefix))
}

/// media playlist（可播放的分片列表）
#[derive(Debug, Clone, PartialEq)]
pub struct MediaPlaylist {
    pub segments: Vec<Segment>,
    /// fMP4 初始化段
    ///
    /// 至多一个：出现第二个 `#EXT-X-MAP` 时解析直接返回 `Err`（多 period
    /// fMP4 不支持，静默取最后一个会把前段拼到错误 init 上）。
    pub init_map: Option<InitMap>,
    /// 是否含 `#EXT-X-ENDLIST`（点播）；false 表示直播/事件流
    pub is_endlist: bool,
}

impl MediaPlaylist {
    /// 是否可作为**完整**内容缓存（点播）
    ///
    /// 仅当 playlist 含 `#EXT-X-ENDLIST` 时为 `true`。直播（live）playlist
    /// 只是当前滑动窗口的快照，按窗口下载只能得到「半章」，**调用方必须**
    /// 在缓存前检查本方法并拒绝 `false`。
    pub fn is_vod(&self) -> bool {
        self.is_endlist
    }
}

/// 一个媒体分片
#[derive(Debug, Clone, PartialEq)]
pub struct Segment {
    /// 分片 URI（已绝对化）
    pub uri: String,
    /// `#EXTINF` 时长（秒）
    pub duration: f64,
    /// 字节区间（offset 已按 §4.3.2.2 补全）
    pub byte_range: Option<ByteRange>,
    /// 该段生效的密钥（继承自上一个 `#EXT-X-KEY`；`METHOD=NONE` 后为 `None`）
    pub key: Option<HlsKey>,
    /// 该段是否紧跟在 `#EXT-X-DISCONTINUITY` 之后
    pub discontinuity: bool,
}

/// fMP4 初始化段
#[derive(Debug, Clone, PartialEq)]
pub struct InitMap {
    /// 初始化段 URI（已绝对化）
    pub uri: String,
    pub byte_range: Option<ByteRange>,
    /// 生效的密钥（`EXT-X-MAP` 出现时的当前 key）
    pub key: Option<HlsKey>,
}

/// 字节区间（`#EXT-X-BYTERANGE:<length>[@<offset>]`）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ByteRange {
    pub length: u64,
    pub offset: u64,
}

/// AES-128 密钥
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HlsKey {
    /// 加密方法原文（当前仅 `AES-128` 会出现在结果中）
    pub method: String,
    /// 密钥 URI（已绝对化）
    pub uri: String,
    /// 16 字节 IV；`IV` 缺省时按 §5.2 用媒体序列号大端填充
    pub iv: Option<[u8; 16]>,
}

/// 解析结果：master 或 media
#[derive(Debug, Clone, PartialEq)]
pub enum Playlist {
    Master(MasterPlaylist),
    Media(MediaPlaylist),
}

/// 解析 m3u8 文本
///
/// - `text`：playlist 原文（自动剥除 UTF-8 BOM）
/// - `base_url`：用于相对路径绝对化的基准（通常是 playlist 自身的 URL）
///
/// 含 `#EXT-X-STREAM-INF` 判定为 master，否则按 media 解析。
pub fn parse_playlist(text: &str, base_url: &str) -> LegadoResult<Playlist> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);

    // 首行必须是 #EXTM3U（RFC 8216 §4.3.1.1）
    match first_non_empty_line(text) {
        Some(line) if tag_name(line).as_deref() == Some("EXTM3U") => {}
        Some(line) => {
            return Err(parse_err(format!(
                "非 M3U 内容：首行应为 #EXTM3U，实际为 {line}"
            )))
        }
        None => return Err(parse_err("空内容：缺少 #EXTM3U 首行")),
    }

    let is_master = text
        .lines()
        .map(str::trim)
        .any(|line| tag_name(line).as_deref() == Some("EXT-X-STREAM-INF"));

    if is_master {
        Ok(Playlist::Master(parse_master(text, base_url)?))
    } else {
        Ok(Playlist::Media(parse_media(text, base_url)?))
    }
}

/// 选档策略：优先**纯音频** variant，其次无视频信号的档，最后最高带宽
///
/// 分三档，逐档回落（同档内取 `BANDWIDTH` 最高者，同带宽取**靠前**者）：
///
/// 1. **明确纯音频**（[`Variant::is_audio_only`]）：无 `RESOLUTION` 且 `CODECS`
///    存在、只列音频编码；
/// 2. **无视频信号**（[`Variant::lacks_video_signal`]）：无 `RESOLUTION` 且
///    `CODECS` 未标明视频编码——**包含 `CODECS` 完全缺失的情况**（纯音频档
///    省略 `CODECS` 相当常见，旧实现会因此误选视频档）；
/// 3. 兜底：全部档位中 `BANDWIDTH` 最高者。
///
/// `RESOLUTION` 是「该档含视频」的强信号，故带分辨率的档永远不会进入前两档。
///
/// 若 master 是「视频档 + `#EXT-X-MEDIA:TYPE=AUDIO` 独立音频轨」的标准形态，
/// 纯音频内容在音频轨里而不在任何 variant 中，调用方应改用
/// [`select_audio_rendition`] 直接取音频轨 URI。
pub fn select_variant(master: &MasterPlaylist) -> Option<&Variant> {
    if master.variants.is_empty() {
        return None;
    }
    if let Some(picked) = pick_max_bandwidth(master.variants.iter().filter(|v| v.is_audio_only())) {
        return Some(picked);
    }
    if let Some(picked) =
        pick_max_bandwidth(master.variants.iter().filter(|v| v.lacks_video_signal()))
    {
        return Some(picked);
    }
    pick_max_bandwidth(master.variants.iter())
}

/// 选「独立音频轨」：`#EXT-X-MEDIA:TYPE=AUDIO` 中带 `URI` 的音轨
///
/// 优先 `DEFAULT=YES`，否则取靠前者。返回 `None` 表示该 master 没有独立音频
/// 播放列表（音频混在 variant 内），此时仍用 [`select_variant`]。
pub fn select_audio_rendition(master: &MasterPlaylist) -> Option<&AudioRendition> {
    let with_uri = || master.audio_groups.iter().filter(|a| a.uri.is_some());
    with_uri().find(|a| a.default).or_else(|| with_uri().next())
}

/// 选**播放列表 URI**：优先独立音频轨，其次 [`select_variant`]
///
/// 这是缓存/播放路径推荐的入口——「视频 variant + 独立音频组」的标准 master
/// 里，纯音频内容只存在于 `#EXT-X-MEDIA:TYPE=AUDIO` 的 `URI`，任何 variant
/// 都是视频档。
pub fn select_playlist_uri(master: &MasterPlaylist) -> Option<&str> {
    if let Some(rendition) = select_audio_rendition(master) {
        if let Some(uri) = rendition.uri.as_deref() {
            return Some(uri);
        }
    }
    select_variant(master).map(|variant| variant.uri.as_str())
}

/// 取带宽最高者；同带宽保留先出现者
fn pick_max_bandwidth<'a>(mut iter: impl Iterator<Item = &'a Variant>) -> Option<&'a Variant> {
    let mut best: Option<&'a Variant> = None;
    for variant in iter.by_ref() {
        match best {
            Some(current) if current.bandwidth >= variant.bandwidth => {}
            _ => best = Some(variant),
        }
    }
    best
}

/// 解析 master playlist
fn parse_master(text: &str, base_url: &str) -> LegadoResult<MasterPlaylist> {
    let mut variants: Vec<Variant> = Vec::new();
    let mut audio_groups: Vec<AudioRendition> = Vec::new();
    // 等待 URI 行的档位属性
    let mut pending: Option<PendingVariant> = None;

    for line in text.lines().map(str::trim) {
        if line.is_empty() {
            continue;
        }
        if let Some(tag) = tag_name(line) {
            match tag.as_str() {
                "EXTM3U" => {}
                "EXT-X-STREAM-INF" => {
                    if pending.is_some() {
                        return Err(parse_err(
                            "master playlist 畸形：#EXT-X-STREAM-INF 后缺少档位 URI",
                        ));
                    }
                    let value = tag_value(line).unwrap_or("");
                    pending = Some(parse_stream_inf(value)?);
                }
                "EXT-X-MEDIA" => {
                    let value = tag_value(line).unwrap_or("");
                    if let Some(rendition) = parse_media_rendition(value, base_url)? {
                        audio_groups.push(rendition);
                    }
                }
                // 未知标签（EXT-X-VERSION / EXT-X-INDEPENDENT-SEGMENTS /
                // EXT-X-I-FRAME-STREAM-INF 等）忽略
                _ => {}
            }
            continue;
        }
        // 裸行 = 档位 URI
        if let Some(pending) = pending.take() {
            variants.push(Variant {
                bandwidth: pending.bandwidth,
                codecs: pending.codecs,
                resolution: pending.resolution,
                audio_group: pending.audio_group,
                uri: absolutize(base_url, line),
            });
        }
        // 无 STREAM-INF 上下文的裸行忽略（容错）
    }

    if pending.is_some() {
        return Err(parse_err(
            "master playlist 畸形：#EXT-X-STREAM-INF 后缺少档位 URI",
        ));
    }
    Ok(MasterPlaylist {
        variants,
        audio_groups,
    })
}

/// `#EXT-X-STREAM-INF` 解析出的待绑定属性（尚未关联 URI）
struct PendingVariant {
    bandwidth: u64,
    codecs: Option<String>,
    resolution: Option<(u32, u32)>,
    audio_group: Option<String>,
}

/// 解析 `#EXT-X-STREAM-INF` 的属性值
fn parse_stream_inf(value: &str) -> LegadoResult<PendingVariant> {
    let attrs = parse_attributes(value)?;
    let mut bandwidth = None;
    let mut codecs = None;
    let mut resolution = None;
    let mut audio_group = None;
    for (name, val) in attrs {
        match name.to_ascii_uppercase().as_str() {
            "BANDWIDTH" => {
                bandwidth = Some(val.trim().parse::<u64>().map_err(|_| {
                    parse_err(format!("EXT-X-STREAM-INF 的 BANDWIDTH 非数字: {val}"))
                })?);
            }
            "CODECS" => codecs = Some(val),
            "RESOLUTION" => resolution = parse_resolution(&val),
            "AUDIO" => audio_group = Some(val.trim().to_string()),
            _ => {}
        }
    }
    let bandwidth = bandwidth.ok_or_else(|| parse_err("EXT-X-STREAM-INF 缺少 BANDWIDTH 属性"))?;
    Ok(PendingVariant {
        bandwidth,
        codecs,
        resolution,
        audio_group,
    })
}

/// 解析 `RESOLUTION=<w>x<h>`；畸形时返回 `None`（视为未声明，不影响可播性）
fn parse_resolution(value: &str) -> Option<(u32, u32)> {
    let (width, height) = value.trim().split_once(['x', 'X'])?;
    let width = width.trim().parse::<u32>().ok()?;
    let height = height.trim().parse::<u32>().ok()?;
    if width == 0 || height == 0 {
        return None;
    }
    Some((width, height))
}

/// 解析 `#EXT-X-MEDIA`；仅保留 `TYPE=AUDIO`，其余类型返回 `None`
fn parse_media_rendition(value: &str, base_url: &str) -> LegadoResult<Option<AudioRendition>> {
    let attrs = parse_attributes(value)?;
    let mut media_type: Option<String> = None;
    let mut group_id: Option<String> = None;
    let mut name: Option<String> = None;
    let mut language: Option<String> = None;
    let mut uri: Option<String> = None;
    let mut default = false;
    for (attr, val) in attrs {
        match attr.to_ascii_uppercase().as_str() {
            "TYPE" => media_type = Some(val.trim().to_string()),
            "GROUP-ID" => group_id = Some(val.trim().to_string()),
            "NAME" => name = Some(val),
            "LANGUAGE" => language = Some(val),
            "URI" => uri = Some(val),
            "DEFAULT" => default = val.trim().eq_ignore_ascii_case("YES"),
            _ => {}
        }
    }
    let is_audio = media_type
        .as_deref()
        .is_some_and(|t| t.eq_ignore_ascii_case("AUDIO"));
    if !is_audio {
        return Ok(None);
    }
    let Some(group_id) = group_id else {
        // TYPE=AUDIO 缺 GROUP-ID：无法被档位引用，忽略（不因可选轨丢整条播放链）
        return Ok(None);
    };
    Ok(Some(AudioRendition {
        group_id,
        name,
        language,
        default,
        uri: uri.map(|u| absolutize(base_url, &u)),
    }))
}

/// media playlist 解析的中间状态
struct MediaState {
    segments: Vec<Segment>,
    init_map: Option<InitMap>,
    is_endlist: bool,
    media_sequence: u64,
    current_key: Option<HlsKey>,
    pending_duration: Option<f64>,
    pending_byte_range: Option<(u64, Option<u64>)>,
    pending_discontinuity: bool,
    /// 上一段的字节区间（URI, 末尾 offset），用于 §4.3.2.2 缺省 offset
    last_range: Option<(String, u64)>,
    /// init map 的缺省 IV 是否已按首个后续段解析
    init_iv_resolved: bool,
}

/// 解析 media playlist
fn parse_media(text: &str, base_url: &str) -> LegadoResult<MediaPlaylist> {
    let mut state = MediaState {
        segments: Vec::new(),
        init_map: None,
        is_endlist: false,
        media_sequence: 0,
        current_key: None,
        pending_duration: None,
        pending_byte_range: None,
        pending_discontinuity: false,
        last_range: None,
        init_iv_resolved: true,
    };

    for line in text.lines().map(str::trim) {
        if line.is_empty() {
            continue;
        }
        let Some(tag) = tag_name(line) else {
            // 裸行 = 分片 URI（仅当有 EXTINF 待消费时）
            if state.pending_duration.is_some() {
                push_segment(&mut state, line, base_url)?;
            }
            // 无 EXTINF 前置的裸行：RFC 8216 §4.3.2.1 要求每个媒体段 URI 前必须有
            // EXTINF，但真实播放列表偶有尾随垃圾行/未标注的附加行。此处**忽略**
            // 而非报错——硬失败会让整条播放链不可用，损失远大于收益。
            continue;
        };
        let value = tag_value(line).unwrap_or("");
        match tag.as_str() {
            "EXTM3U" => {}
            "EXTINF" => {
                if state.pending_duration.is_some() {
                    return Err(parse_err("media playlist 畸形：EXTINF 后缺少分片 URI"));
                }
                let duration_text = value.split(',').next().unwrap_or("").trim();
                let duration = duration_text
                    .parse::<f64>()
                    .map_err(|_| parse_err(format!("EXTINF 时长非数字: {duration_text}")))?;
                state.pending_duration = Some(duration);
            }
            "EXT-X-KEY" => {
                state.current_key = parse_key(value, base_url)?;
            }
            "EXT-X-MAP" => {
                if state.init_map.is_some() {
                    // 多 period fMP4：换 init map（通常还换 key）。单一 init_map
                    // 无法覆盖全部段，静默取最后一个会把前段拼到错误 init 上，
                    // 产物不可播且无任何报错——宁可直接失败。
                    return Err(parse_err(
                        "不支持多 period fMP4（多个 EXT-X-MAP）：无法用单一 init map 覆盖全部分片",
                    ));
                }
                state.init_map = Some(parse_map(value, base_url, &state.current_key)?);
                state.init_iv_resolved = false;
            }
            "EXT-X-BYTERANGE" => {
                state.pending_byte_range = Some(parse_byte_range(value)?);
            }
            "EXT-X-DISCONTINUITY" => {
                state.pending_discontinuity = true;
            }
            "EXT-X-MEDIA-SEQUENCE" => {
                state.media_sequence = value
                    .trim()
                    .parse::<u64>()
                    .map_err(|_| parse_err(format!("EXT-X-MEDIA-SEQUENCE 非数字: {value}")))?;
            }
            "EXT-X-ENDLIST" => {
                state.is_endlist = true;
            }
            "EXT-X-I-FRAMES-ONLY" => {
                return Err(parse_err(
                    "不支持的 HLS 标签：EXT-X-I-FRAMES-ONLY（仅 I 帧播放列表未实现）",
                ));
            }
            // 其余标签（VERSION / TARGETDURATION / PLAYLIST-TYPE / PROGRAM-DATE-TIME 等）忽略
            _ => {}
        }
    }

    if state.pending_duration.is_some() {
        return Err(parse_err("media playlist 畸形：EXTINF 后缺少分片 URI"));
    }

    Ok(MediaPlaylist {
        segments: state.segments,
        init_map: state.init_map,
        is_endlist: state.is_endlist,
    })
}

/// 把一行分片 URI 落成 [`Segment`]（消费 pending 状态）
fn push_segment(state: &mut MediaState, uri_line: &str, base_url: &str) -> LegadoResult<()> {
    let duration = state
        .pending_duration
        .take()
        .expect("调用方已确认 pending_duration 为 Some");
    let uri = absolutize(base_url, uri_line);

    // §4.3.2.2：offset 缺省时紧接同一 URI 上一段的末尾
    let byte_range = match state.pending_byte_range.take() {
        Some((length, Some(offset))) => Some(ByteRange { length, offset }),
        Some((length, None)) => {
            let offset = match &state.last_range {
                Some((last_uri, last_end)) if *last_uri == uri => *last_end,
                _ => 0,
            };
            Some(ByteRange { length, offset })
        }
        None => None,
    };

    match byte_range {
        Some(range) => state.last_range = Some((uri.clone(), range.offset + range.length)),
        // 无字节区间的段使「上一段末尾」语义失效，回落到 0
        None => state.last_range = None,
    }

    // §5.2：IV 缺省时用「媒体序列号」= MEDIA-SEQUENCE + 段下标
    let index = state.segments.len() as u64;
    let sequence = state.media_sequence.wrapping_add(index);
    let default_iv = iv_from_sequence(sequence);

    let mut key = state.current_key.clone();
    if let Some(key) = key.as_mut() {
        if key.iv.is_none() {
            key.iv = Some(default_iv);
        }
    }

    // init map 的缺省 IV 用紧随其后的第一个段序列号（与播放器口径一致）
    if let Some(map) = state.init_map.as_mut() {
        if !state.init_iv_resolved {
            // 兼容 KEY 出现在 MAP 之后的写法（RFC 未禁止）：首个段生效的 key 即 map 的 key
            if map.key.is_none() {
                map.key = state.current_key.clone();
            }
            if let Some(map_key) = map.key.as_mut() {
                if map_key.iv.is_none() {
                    map_key.iv = Some(default_iv);
                }
            }
            state.init_iv_resolved = true;
        }
    }

    state.segments.push(Segment {
        uri,
        duration,
        byte_range,
        key,
        discontinuity: std::mem::take(&mut state.pending_discontinuity),
    });
    Ok(())
}

/// 解析 `#EXT-X-KEY` 属性，返回该标签之后生效的密钥
fn parse_key(value: &str, base_url: &str) -> LegadoResult<Option<HlsKey>> {
    let attrs = parse_attributes(value)?;
    let mut method: Option<String> = None;
    let mut uri: Option<String> = None;
    let mut iv: Option<[u8; 16]> = None;
    for (name, val) in attrs {
        match name.to_ascii_uppercase().as_str() {
            "METHOD" => method = Some(val.trim().to_string()),
            "URI" => uri = Some(val),
            "IV" => iv = Some(parse_iv(&val)?),
            _ => {}
        }
    }
    let method = method.ok_or_else(|| parse_err("EXT-X-KEY 缺少 METHOD 属性"))?;
    let upper = method.to_ascii_uppercase();

    if upper == "NONE" {
        // 显式终止继承
        return Ok(None);
    }
    if upper == "AES-128" {
        let uri = uri.ok_or_else(|| parse_err("EXT-X-KEY(METHOD=AES-128) 缺少 URI 属性"))?;
        return Ok(Some(HlsKey {
            method,
            uri: absolutize(base_url, &uri),
            iv,
        }));
    }
    if upper.starts_with("SAMPLE-AES") {
        return Err(parse_err(format!(
            "不支持的 HLS 加密方式：{method}（SAMPLE-AES 系未实现）"
        )));
    }
    Err(parse_err(format!("不支持的 HLS 加密方式：{method}")))
}

/// 解析 `#EXT-X-MAP`
fn parse_map(value: &str, base_url: &str, current_key: &Option<HlsKey>) -> LegadoResult<InitMap> {
    let attrs = parse_attributes(value)?;
    let mut uri: Option<String> = None;
    let mut byte_range: Option<ByteRange> = None;
    for (name, val) in attrs {
        match name.to_ascii_uppercase().as_str() {
            "URI" => uri = Some(val),
            "BYTERANGE" => {
                // 初始化段独立资源：缺省 offset 取 0
                let (length, offset) = parse_byte_range(&val)?;
                byte_range = Some(ByteRange {
                    length,
                    offset: offset.unwrap_or(0),
                });
            }
            _ => {}
        }
    }
    let uri = uri.ok_or_else(|| parse_err("EXT-X-MAP 缺少 URI 属性"))?;
    Ok(InitMap {
        uri: absolutize(base_url, &uri),
        byte_range,
        key: current_key.clone(),
    })
}

/// 解析 `n[@o]` 字节区间
fn parse_byte_range(value: &str) -> LegadoResult<(u64, Option<u64>)> {
    let value = value.trim();
    let (length_text, offset_text) = match value.split_once('@') {
        Some((length, offset)) => (length, Some(offset)),
        None => (value, None),
    };
    let length = length_text
        .trim()
        .parse::<u64>()
        .map_err(|_| parse_err(format!("EXT-X-BYTERANGE 长度非数字: {value}")))?;
    let offset = match offset_text {
        Some(text) => Some(
            text.trim()
                .parse::<u64>()
                .map_err(|_| parse_err(format!("EXT-X-BYTERANGE 偏移非数字: {value}")))?,
        ),
        None => None,
    };
    Ok((length, offset))
}

/// 解析 `0x` 前缀十六进制 IV，左补零到 16 字节
fn parse_iv(value: &str) -> LegadoResult<[u8; 16]> {
    let raw = value.trim();
    let hex = raw
        .strip_prefix("0x")
        .or_else(|| raw.strip_prefix("0X"))
        .unwrap_or(raw);
    if hex.is_empty() {
        return Err(parse_err(format!("EXT-X-KEY 的 IV 为空: {raw}")));
    }
    if hex.len() > 32 {
        return Err(parse_err(format!(
            "EXT-X-KEY 的 IV 超长（>16 字节）: {raw}"
        )));
    }
    if !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(parse_err(format!("EXT-X-KEY 的 IV 非十六进制: {raw}")));
    }
    let padded = format!("{hex:0>32}");
    let mut iv = [0u8; 16];
    for (index, chunk) in padded.as_bytes().chunks(2).enumerate() {
        // 已校验为 ASCII 十六进制，且长度为 32，不会失败
        iv[index] = u8::from_str_radix(std::str::from_utf8(chunk).unwrap_or("00"), 16)
            .map_err(|_| parse_err(format!("EXT-X-KEY 的 IV 解析失败: {raw}")))?;
    }
    Ok(iv)
}

/// 序列号 → 128-bit 大端 IV（RFC 8216 §5.2）
fn iv_from_sequence(sequence: u64) -> [u8; 16] {
    let mut iv = [0u8; 16];
    iv[8..].copy_from_slice(&sequence.to_be_bytes());
    iv
}

/// 相对 URI 绝对化（复用 legado-parser 的 `get_absolute_url`）
///
/// `get_absolute_url` 服务于书源规则拼接，**不做**点段（`.`/`..`）规范化；
/// HLS 的分片 URI 必须按 RFC 3986 §5.2.4 处理，否则 `../up/seg.ts` 会拼出
/// `https://host/media/../up/seg.ts` 这类未规范化的路径。故此处补一层
/// [`normalize_dot_segments`]。
fn absolutize(base_url: &str, uri: &str) -> String {
    let uri = uri.trim();
    if base_url.trim().is_empty() {
        return uri.to_string();
    }
    normalize_dot_segments(&AnalyzeUrl::get_absolute_url(base_url, uri))
}

/// 移除 URI 路径中的 `.` / `..` 点段（RFC 3986 §5.2.4）
///
/// 只处理 scheme://authority 之后的 path 部分，query/fragment 原样保留；
/// 非绝对 URI（无 `://`）原样返回。
fn normalize_dot_segments(url: &str) -> String {
    let Some(scheme_end) = url.find("://") else {
        return url.to_string();
    };
    let authority_start = scheme_end + 3;
    let Some(offset) = url[authority_start..].find('/') else {
        // 无 path（如 `https://host`），无需处理
        return url.to_string();
    };
    let path_start = authority_start + offset;
    let path_and_rest = &url[path_start..];
    let (path, suffix) = match path_and_rest.find(['?', '#']) {
        Some(pos) => (&path_and_rest[..pos], &path_and_rest[pos..]),
        None => (path_and_rest, ""),
    };
    if !path.contains("/./")
        && !path.contains("/../")
        && !path.ends_with("/.")
        && !path.ends_with("/..")
    {
        return url.to_string();
    }

    let mut segments: Vec<&str> = Vec::new();
    for segment in path.split('/') {
        match segment {
            "." => {}
            ".." => {
                // 保留开头的空串（绝对路径前导 '/'），且不得越过根
                if segments.len() > 1 {
                    segments.pop();
                }
            }
            other => segments.push(other),
        }
    }
    let normalized_path = segments.join("/");
    format!("{}{}{}", &url[..path_start], normalized_path, suffix)
}

/// 解析属性列表（`KEY=value,KEY="quoted,value"`）
///
/// 引号内的逗号不作为分隔符；引号内不允许出现 `"` 与换行（RFC 8216 §4.2）。
fn parse_attributes(input: &str) -> LegadoResult<Vec<(String, String)>> {
    let mut out: Vec<(String, String)> = Vec::new();
    let mut rest = input;
    loop {
        rest = rest.trim_start_matches(|c: char| c == ',' || c.is_whitespace());
        if rest.is_empty() {
            break;
        }
        let eq = rest
            .find('=')
            .ok_or_else(|| parse_err(format!("属性缺少 '=': {rest}")))?;
        let name = rest[..eq].trim();
        if name.is_empty() {
            return Err(parse_err(format!("属性名为空: {rest}")));
        }
        let after_eq = &rest[eq + 1..];
        let leading_ws = after_eq.len() - after_eq.trim_start().len();
        let value_start = eq + 1 + leading_ws;
        let tail = &rest[value_start..];

        let (value, next_index) = if let Some(quoted) = tail.strip_prefix('"') {
            let end = quoted
                .find('"')
                .ok_or_else(|| parse_err(format!("属性值引号未闭合: {name}")))?;
            (quoted[..end].to_string(), value_start + 1 + end + 1)
        } else {
            match tail.find(',') {
                Some(comma) => (tail[..comma].trim().to_string(), value_start + comma + 1),
                None => (tail.trim().to_string(), rest.len()),
            }
        };

        out.push((name.to_string(), value));
        rest = &rest[next_index..];
    }
    Ok(out)
}

/// 取首个非空行
fn first_non_empty_line(text: &str) -> Option<&str> {
    text.lines().map(str::trim).find(|line| !line.is_empty())
}

/// 标签名（`#EXT-X-KEY:...` → `EXT-X-KEY`）；非标签行返回 `None`
fn tag_name(line: &str) -> Option<String> {
    let rest = line.strip_prefix('#')?;
    let name = rest.split(':').next().unwrap_or(rest).trim();
    if name.is_empty() {
        return None;
    }
    Some(name.to_ascii_uppercase())
}

/// 标签值（`#EXTINF:4.0,` → `4.0,`）；无冒号返回 `None`
fn tag_value(line: &str) -> Option<&str> {
    line.split_once(':').map(|(_, value)| value)
}

fn parse_err(message: impl Into<String>) -> LegadoError {
    LegadoError::Parser(message.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = "https://cdn.example.com/media/index.m3u8";

    fn parse_media_only(text: &str) -> MediaPlaylist {
        match parse_playlist(text, BASE).expect("应解析成功") {
            Playlist::Media(media) => media,
            Playlist::Master(master) => panic!("预期 media，实际 master: {master:?}"),
        }
    }

    fn parse_master_only(text: &str) -> MasterPlaylist {
        match parse_playlist(text, BASE).expect("应解析成功") {
            Playlist::Master(master) => master,
            Playlist::Media(media) => panic!("预期 master，实际 media: {media:?}"),
        }
    }

    // ---------- master：选档策略 ----------

    #[test]
    fn master_audio_only_preferred_over_higher_bandwidth_video() {
        let text = "\
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=5000000,CODECS=\"avc1.640028,mp4a.40.2\",RESOLUTION=1920x1080
video_1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS=\"mp4a.40.2\"
audio.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS=\"avc1.4d401f,mp4a.40.2\"
video_480.m3u8
";
        let master = parse_master_only(text);
        assert_eq!(master.variants.len(), 3);
        assert_eq!(master.variants[0].bandwidth, 5_000_000);
        assert_eq!(
            master.variants[0].codecs.as_deref(),
            Some("avc1.640028,mp4a.40.2")
        );
        let picked = select_variant(&master).expect("应有选中档位");
        assert_eq!(picked.uri, "https://cdn.example.com/media/audio.m3u8");
    }

    #[test]
    fn master_audio_only_picks_highest_bandwidth_among_audio() {
        let text = "\
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS=\"mp4a.40.2\"
a_low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=192000,CODECS=\"mp4a.40.2\"
a_high.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS=\"avc1.4d401f,mp4a.40.2\"
v.m3u8
";
        let master = parse_master_only(text);
        let picked = select_variant(&master).expect("应有选中档位");
        assert_eq!(picked.bandwidth, 192_000);
        assert_eq!(picked.uri, "https://cdn.example.com/media/a_high.m3u8");
    }

    #[test]
    fn master_falls_back_to_highest_bandwidth_without_audio_only() {
        let text = "\
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS=\"avc1.4d401f,mp4a.40.2\"
v_480.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,CODECS=\"hvc1.1.6.L93.B0,mp4a.40.2\"
v_1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1500000,CODECS=\"hev1.1.6.L93.B0,mp4a.40.2\"
v_720.m3u8
";
        let master = parse_master_only(text);
        let picked = select_variant(&master).expect("应有选中档位");
        assert_eq!(picked.bandwidth, 3_000_000);
        assert_eq!(picked.uri, "https://cdn.example.com/media/v_1080.m3u8");
    }

    #[test]
    fn master_without_codecs_prefers_variant_without_resolution() {
        // CODECS 全缺失：两档都「无视频信号」，仍取最高带宽（第二档回落）
        let text = "\
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=100000
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=900000
high.m3u8
";
        let master = parse_master_only(text);
        assert_eq!(master.variants[0].codecs, None);
        let picked = select_variant(&master).expect("应有选中档位");
        assert_eq!(picked.bandwidth, 900_000);
    }

    #[test]
    fn master_audio_without_codecs_beats_video_with_avc1() {
        // P2-3 回归：纯音频档省略 CODECS，视频档写了 avc1。
        // 旧实现 audio_only 为空 → 回落最高带宽 → 误选视频档。
        let text = "\
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS=\"avc1.640028,mp4a.40.2\"
video.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=128000
audio_no_codecs.m3u8
";
        let master = parse_master_only(text);
        let picked = select_variant(&master).expect("应有选中档位");
        assert_eq!(
            picked.uri,
            "https://cdn.example.com/media/audio_no_codecs.m3u8"
        );
        assert_eq!(picked.bandwidth, 128_000);
    }

    #[test]
    fn master_resolution_without_codecs_is_video() {
        // RESOLUTION 是视频强信号：即使 CODECS 缺失也不能当作音频候选
        let text = "\
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
video.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS=\"mp4a.40.2\"
audio.m3u8
";
        let master = parse_master_only(text);
        assert_eq!(master.variants[0].resolution, Some((1920, 1080)));
        assert!(master.variants[0].has_video());
        let picked = select_variant(&master).expect("应有选中档位");
        assert_eq!(picked.uri, "https://cdn.example.com/media/audio.m3u8");
    }

    #[test]
    fn master_av1_and_vp9_variants_are_not_audio_only() {
        // av01 / vp09 / vp08 / dvhe 等新编码必须被识别为视频档
        let text = "\
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=3000000,CODECS=\"av01.0.05M.08\"
av1.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS=\"vp09.00.10.08\"
vp9.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS=\"vp08.00.41.08\"
vp8.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,CODECS=\"dvh1.05.06\"
dovi.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS=\"opus\"
audio.m3u8
";
        let master = parse_master_only(text);
        assert!(master.variants[..4].iter().all(|v| v.has_video()));
        assert!(master.variants[..4].iter().all(|v| !v.is_audio_only()));
        assert!(master.variants[4].is_audio_only());
        let picked = select_variant(&master).expect("应有选中档位");
        assert_eq!(picked.uri, "https://cdn.example.com/media/audio.m3u8");
    }

    #[test]
    fn master_resolution_variant_never_outranks_resolutionless() {
        // 有 RESOLUTION 的档（即便 CODECS 缺失）不得优先于无 RESOLUTION 的档
        let text = "\
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=3840x2160
uhd.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=64000
maybe_audio.m3u8
";
        let master = parse_master_only(text);
        let picked = select_variant(&master).expect("应有选中档位");
        assert_eq!(picked.uri, "https://cdn.example.com/media/maybe_audio.m3u8");
    }

    #[test]
    fn master_audio_rendition_group_parsed_and_selected() {
        // 只有视频 variant + 独立音频组（标准形态）：应能取到音频组 URI
        let text = "\
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"cn\",DEFAULT=YES,URI=\"audio_cn.m3u8\"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"en\",URI=\"audio_en.m3u8\"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"sub\",NAME=\"cn\",URI=\"sub.m3u8\"
#EXT-X-STREAM-INF:BANDWIDTH=5000000,CODECS=\"avc1.640028,mp4a.40.2\",RESOLUTION=1920x1080,AUDIO=\"aud\"
video_1080.m3u8
";
        let master = parse_master_only(text);
        assert_eq!(master.variants.len(), 1);
        // 非 AUDIO 类型不入列
        assert_eq!(master.audio_groups.len(), 2);
        assert_eq!(master.audio_groups[0].group_id, "aud");
        assert_eq!(master.audio_groups[0].name.as_deref(), Some("cn"));
        assert!(master.audio_groups[0].default);
        assert_eq!(
            master.audio_groups[0].uri.as_deref(),
            Some("https://cdn.example.com/media/audio_cn.m3u8")
        );
        assert!(!master.audio_groups[1].default);
        assert_eq!(master.variants[0].audio_group.as_deref(), Some("aud"));

        // 独立音频组优先（DEFAULT=YES）
        let rendition = select_audio_rendition(&master).expect("应有音频轨");
        assert_eq!(rendition.name.as_deref(), Some("cn"));
        assert_eq!(
            select_playlist_uri(&master),
            Some("https://cdn.example.com/media/audio_cn.m3u8")
        );
        // select_variant 仍只看 variant（此 master 全是视频档 → 兜底最高带宽）
        assert_eq!(
            select_variant(&master).map(|v| v.uri.as_str()),
            Some("https://cdn.example.com/media/video_1080.m3u8")
        );
    }

    #[test]
    fn master_audio_rendition_without_uri_falls_back_to_variant() {
        let text = "\
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"cn\",DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS=\"mp4a.40.2\",AUDIO=\"aud\"
audio.m3u8
";
        let master = parse_master_only(text);
        assert!(master.audio_groups[0].uri.is_none());
        assert!(select_audio_rendition(&master).is_none());
        assert_eq!(
            select_playlist_uri(&master),
            Some("https://cdn.example.com/media/audio.m3u8")
        );
    }

    #[test]
    fn master_ties_keep_first_variant() {
        let text = "\
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS=\"avc1.4d401f\"
first.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS=\"avc1.4d401f\"
second.m3u8
";
        let master = parse_master_only(text);
        let picked = select_variant(&master).expect("应有选中档位");
        assert_eq!(picked.uri, "https://cdn.example.com/media/first.m3u8");
    }

    #[test]
    fn master_empty_variants_select_none() {
        let master = parse_master_only("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nx.m3u8\n");
        assert_eq!(
            select_variant(&master).unwrap().uri,
            "https://cdn.example.com/media/x.m3u8"
        );
        let empty = MasterPlaylist {
            variants: vec![],
            audio_groups: vec![],
        };
        assert!(select_variant(&empty).is_none());
    }

    #[test]
    fn master_variant_uri_forms_absolutized() {
        let text = "\
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS=\"mp4a.40.2\"
//other.example.com/a.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000,CODECS=\"mp4a.40.2\"
/root/b.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000,CODECS=\"mp4a.40.2\"
sub/c.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4000,CODECS=\"mp4a.40.2\"
https://abs.example.com/d.m3u8
";
        let master = parse_master_only(text);
        let uris: Vec<&str> = master.variants.iter().map(|v| v.uri.as_str()).collect();
        assert_eq!(
            uris,
            vec![
                "https://other.example.com/a.m3u8",
                "https://cdn.example.com/root/b.m3u8",
                "https://cdn.example.com/media/sub/c.m3u8",
                "https://abs.example.com/d.m3u8",
            ]
        );
    }

    #[test]
    fn master_ignores_unknown_tags_and_comments() {
        let text = "\
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
# a comment line
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"cn\",URI=\"audio_cn.m3u8\"

#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS=\"mp4a.40.2\",AUDIO=\"aud\"
audio.m3u8
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100000,URI=\"iframe.m3u8\"
";
        let master = parse_master_only(text);
        assert_eq!(master.variants.len(), 1);
        assert_eq!(
            master.variants[0].uri,
            "https://cdn.example.com/media/audio.m3u8"
        );
    }

    // ---------- media：基本解析 ----------

    #[test]
    fn media_basic_segments() {
        let text = "\
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:9.009,
seg0.ts
#EXTINF:9.009,title ignored
seg1.ts
#EXTINF:3.003,
https://abs.example.com/seg2.ts
#EXT-X-ENDLIST
";
        let media = parse_media_only(text);
        assert!(media.is_endlist);
        assert!(media.init_map.is_none());
        assert_eq!(media.segments.len(), 3);
        assert_eq!(
            media.segments[0].uri,
            "https://cdn.example.com/media/seg0.ts"
        );
        assert_eq!(media.segments[0].duration, 9.009);
        assert_eq!(media.segments[1].duration, 9.009);
        assert_eq!(
            media.segments[1].uri,
            "https://cdn.example.com/media/seg1.ts"
        );
        assert_eq!(media.segments[2].uri, "https://abs.example.com/seg2.ts");
        assert!(!media.segments[0].discontinuity);
        assert!(media.segments.iter().all(|s| s.key.is_none()));
        assert!(media.segments.iter().all(|s| s.byte_range.is_none()));
    }

    #[test]
    fn media_relative_and_protocol_relative_uris() {
        let text = "\
#EXTM3U
#EXTINF:4,
//cdn2.example.com/seg0.ts
#EXTINF:4,
/root/seg1.ts
#EXTINF:4,
../up/seg2.ts
";
        let media = parse_media_only(text);
        let uris: Vec<&str> = media.segments.iter().map(|s| s.uri.as_str()).collect();
        assert_eq!(
            uris,
            vec![
                "https://cdn2.example.com/seg0.ts",
                "https://cdn.example.com/root/seg1.ts",
                "https://cdn.example.com/up/seg2.ts",
            ]
        );
    }

    #[test]
    fn media_not_endlist_when_live() {
        let media = parse_media_only("#EXTM3U\n#EXTINF:4,\nseg.ts\n");
        assert!(!media.is_endlist);
        assert_eq!(media.segments.len(), 1);
    }

    #[test]
    fn media_is_vod_tracks_endlist() {
        // P2-5：live 快照必须能被识别（is_vod=false），由调用方拒绝缓存
        let live = parse_media_only("#EXTM3U\n#EXTINF:4,\nseg.ts\n");
        assert!(!live.is_vod());
        let vod = parse_media_only("#EXTM3U\n#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST\n");
        assert!(vod.is_vod());
        // 事件流（无 ENDLIST 但有 PLAYLIST-TYPE:EVENT）同样是未完结快照
        let event = parse_media_only("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXTINF:4,\nseg.ts\n");
        assert!(!event.is_vod());
    }

    #[test]
    fn media_multiple_ext_x_map_is_error() {
        // P2-4：多 period fMP4（换 init map）不能被静默拼成「最后一个 init + 全部段」
        let text = "\
#EXTM3U
#EXT-X-MAP:URI=\"init_p1.mp4\"
#EXTINF:4,
seg0.m4s
#EXT-X-DISCONTINUITY
#EXT-X-KEY:METHOD=AES-128,URI=\"k2.key\"
#EXT-X-MAP:URI=\"init_p2.mp4\"
#EXTINF:4,
seg1.m4s
#EXT-X-ENDLIST
";
        let err = parse_playlist(text, BASE).expect_err("多个 EXT-X-MAP 必须报错");
        let message = err.to_string();
        assert!(message.contains("EXT-X-MAP"), "message={message}");
        assert!(message.contains("多 period"), "message={message}");
        assert_eq!(err.to_error_code(), 1001);
    }

    #[test]
    fn media_single_ext_x_map_repeated_uri_still_error() {
        // 即使 URI 相同，第二个 EXT-X-MAP 也说明存在 period 切换语义歧义
        let text = "\
#EXTM3U
#EXT-X-MAP:URI=\"init.mp4\"
#EXTINF:4,
seg0.m4s
#EXT-X-MAP:URI=\"init.mp4\"
#EXTINF:4,
seg1.m4s
";
        assert!(parse_playlist(text, BASE).is_err());
    }

    // ---------- media：BYTERANGE ----------

    #[test]
    fn media_byterange_explicit_offset() {
        let text = "\
#EXTM3U
#EXTINF:4,
#EXT-X-BYTERANGE:1000@0
file.mp4
#EXTINF:4,
#EXT-X-BYTERANGE:2000@1000
file.mp4
";
        let media = parse_media_only(text);
        assert_eq!(
            media.segments[0].byte_range,
            Some(ByteRange {
                length: 1000,
                offset: 0
            })
        );
        assert_eq!(
            media.segments[1].byte_range,
            Some(ByteRange {
                length: 2000,
                offset: 1000
            })
        );
    }

    #[test]
    fn media_byterange_default_offset_chains_same_uri() {
        let text = "\
#EXTM3U
#EXTINF:4,
#EXT-X-BYTERANGE:1000@500
file.mp4
#EXTINF:4,
#EXT-X-BYTERANGE:2000
file.mp4
#EXTINF:4,
#EXT-X-BYTERANGE:3000
file.mp4
";
        let media = parse_media_only(text);
        assert_eq!(
            media.segments[1].byte_range,
            Some(ByteRange {
                length: 2000,
                offset: 1500
            })
        );
        assert_eq!(
            media.segments[2].byte_range,
            Some(ByteRange {
                length: 3000,
                offset: 3500
            })
        );
    }

    #[test]
    fn media_byterange_default_offset_without_previous_range_is_zero() {
        let text = "\
#EXTM3U
#EXTINF:4,
#EXT-X-BYTERANGE:1000
file.mp4
";
        let media = parse_media_only(text);
        assert_eq!(
            media.segments[0].byte_range,
            Some(ByteRange {
                length: 1000,
                offset: 0
            })
        );
    }

    #[test]
    fn media_byterange_default_offset_resets_after_plain_segment() {
        let text = "\
#EXTM3U
#EXTINF:4,
#EXT-X-BYTERANGE:1000@0
file.mp4
#EXTINF:4,
whole.ts
#EXTINF:4,
#EXT-X-BYTERANGE:500
file.mp4
";
        let media = parse_media_only(text);
        assert_eq!(media.segments[1].byte_range, None);
        assert_eq!(
            media.segments[2].byte_range,
            Some(ByteRange {
                length: 500,
                offset: 0
            })
        );
    }

    #[test]
    fn media_byterange_default_offset_different_uri_is_zero() {
        let text = "\
#EXTM3U
#EXTINF:4,
#EXT-X-BYTERANGE:1000@500
a.mp4
#EXTINF:4,
#EXT-X-BYTERANGE:700
b.mp4
";
        let media = parse_media_only(text);
        assert_eq!(
            media.segments[1].byte_range,
            Some(ByteRange {
                length: 700,
                offset: 0
            })
        );
    }

    // ---------- media：EXT-X-MAP ----------

    #[test]
    fn media_ext_x_map_with_byterange_and_key() {
        let text = "\
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-KEY:METHOD=AES-128,URI=\"https://keys.example.com/k1\",IV=0x000102030405060708090a0b0c0d0e0f
#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"720@0\"
#EXTINF:4,
seg0.m4s
#EXT-X-ENDLIST
";
        let media = parse_media_only(text);
        let map = media.init_map.expect("应有 init map");
        assert_eq!(map.uri, "https://cdn.example.com/media/init.mp4");
        assert_eq!(
            map.byte_range,
            Some(ByteRange {
                length: 720,
                offset: 0
            })
        );
        let map_key = map.key.expect("init map 应继承 key");
        assert_eq!(map_key.method, "AES-128");
        assert_eq!(map_key.uri, "https://keys.example.com/k1");
        assert_eq!(
            map_key.iv,
            Some([
                0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
                0x0e, 0x0f
            ])
        );
    }

    #[test]
    fn media_ext_x_map_byterange_default_offset_zero() {
        let media = parse_media_only(
            "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"500\"\n#EXTINF:4,\nseg0.m4s\n",
        );
        let map = media.init_map.expect("应有 init map");
        assert_eq!(
            map.byte_range,
            Some(ByteRange {
                length: 500,
                offset: 0
            })
        );
        assert!(map.key.is_none());
    }

    #[test]
    fn media_ext_x_map_default_iv_uses_first_following_segment_sequence() {
        let text = "\
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:5
#EXT-X-KEY:METHOD=AES-128,URI=\"k.key\"
#EXT-X-MAP:URI=\"init.mp4\"
#EXTINF:4,
seg0.m4s
";
        let media = parse_media_only(text);
        let map = media.init_map.expect("应有 init map");
        assert_eq!(map.key.and_then(|k| k.iv), Some(iv_from_sequence(5)));
    }

    // ---------- media：AES-128 key ----------

    #[test]
    fn media_aes128_key_inherited_with_explicit_iv() {
        let text = "\
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI=\"key1.key\",IV=0xAABBCCDDEEFF00112233445566778899
#EXTINF:4,
seg0.ts
#EXTINF:4,
seg1.ts
";
        let media = parse_media_only(text);
        let expected = [
            0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99,
        ];
        for segment in &media.segments {
            let key = segment.key.as_ref().expect("每段都应继承 key");
            assert_eq!(key.method, "AES-128");
            assert_eq!(key.uri, "https://cdn.example.com/media/key1.key");
            assert_eq!(key.iv, Some(expected));
        }
    }

    #[test]
    fn media_aes128_default_iv_uses_media_sequence_and_index() {
        let text = "\
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:7
#EXT-X-KEY:METHOD=AES-128,URI=\"k.key\"
#EXTINF:4,
seg0.ts
#EXTINF:4,
seg1.ts
#EXTINF:4,
seg2.ts
";
        let media = parse_media_only(text);
        assert_eq!(
            media.segments[0].key.as_ref().and_then(|k| k.iv),
            Some(iv_from_sequence(7))
        );
        assert_eq!(
            media.segments[1].key.as_ref().and_then(|k| k.iv),
            Some(iv_from_sequence(8))
        );
        assert_eq!(
            media.segments[2].key.as_ref().and_then(|k| k.iv),
            Some(iv_from_sequence(9))
        );
        // 大端：高 8 字节为 0，低 8 字节为序列号
        let iv = iv_from_sequence(7);
        assert_eq!(&iv[..8], &[0u8; 8]);
        assert_eq!(&iv[8..], &7u64.to_be_bytes());
    }

    #[test]
    fn media_aes128_default_iv_without_media_sequence_starts_at_zero() {
        let media = parse_media_only(
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k.key\"\n#EXTINF:4,\nseg0.ts\n",
        );
        assert_eq!(
            media.segments[0].key.as_ref().and_then(|k| k.iv),
            Some(iv_from_sequence(0))
        );
    }

    #[test]
    fn media_key_none_stops_inheritance() {
        let text = "\
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI=\"k.key\",IV=0x00000000000000000000000000000001
#EXTINF:4,
seg0.ts
#EXT-X-KEY:METHOD=NONE
#EXTINF:4,
seg1.ts
";
        let media = parse_media_only(text);
        assert!(media.segments[0].key.is_some());
        assert!(media.segments[1].key.is_none());
    }

    #[test]
    fn media_key_switch_mid_playlist() {
        let text = "\
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI=\"k1.key\",IV=0x01
#EXTINF:4,
seg0.ts
#EXT-X-KEY:METHOD=AES-128,URI=\"https://other.example.com/k2.key\",IV=0x02
#EXTINF:4,
seg1.ts
";
        let media = parse_media_only(text);
        assert_eq!(
            media.segments[0].key.as_ref().map(|k| k.uri.as_str()),
            Some("https://cdn.example.com/media/k1.key")
        );
        assert_eq!(
            media.segments[1].key.as_ref().map(|k| k.uri.as_str()),
            Some("https://other.example.com/k2.key")
        );
    }

    #[test]
    fn media_iv_shorter_than_16_bytes_is_left_padded() {
        let media = parse_media_only(
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k.key\",IV=0x1\n#EXTINF:4,\nseg0.ts\n",
        );
        let mut expected = [0u8; 16];
        expected[15] = 1;
        assert_eq!(
            media.segments[0].key.as_ref().and_then(|k| k.iv),
            Some(expected)
        );
    }

    // ---------- media：DISCONTINUITY ----------

    #[test]
    fn media_discontinuity_marks_following_segment() {
        let text = "\
#EXTM3U
#EXTINF:4,
seg0.ts
#EXT-X-DISCONTINUITY
#EXTINF:4,
seg1.ts
#EXTINF:4,
seg2.ts
";
        let media = parse_media_only(text);
        assert!(!media.segments[0].discontinuity);
        assert!(media.segments[1].discontinuity);
        assert!(!media.segments[2].discontinuity);
    }

    // ---------- 不支持项：显式报错 ----------

    #[test]
    fn media_sample_aes_is_error() {
        let err = parse_playlist(
            "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key\"\n#EXTINF:4,\nseg.ts\n",
            BASE,
        )
        .expect_err("SAMPLE-AES 必须报错");
        let message = err.to_string();
        assert!(message.contains("SAMPLE-AES"), "message={message}");
        assert_eq!(err.to_error_code(), 1001);
    }

    #[test]
    fn media_sample_aes_ctr_is_error() {
        assert!(parse_playlist(
            "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI=\"skd://key\"\n#EXTINF:4,\nseg.ts\n",
            BASE,
        )
        .is_err());
    }

    #[test]
    fn media_unknown_key_method_is_error() {
        let err = parse_playlist(
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-256,URI=\"k.key\"\n#EXTINF:4,\nseg.ts\n",
            BASE,
        )
        .expect_err("未知加密方式必须报错");
        assert!(err.to_string().contains("AES-256"));
    }

    #[test]
    fn media_i_frames_only_is_error() {
        let err = parse_playlist("#EXTM3U\n#EXT-X-I-FRAMES-ONLY\n#EXTINF:4,\nseg.ts\n", BASE)
            .expect_err("I-FRAMES-ONLY 必须报错");
        assert!(err.to_string().contains("I-FRAMES-ONLY"));
    }

    // ---------- 畸形输入 ----------

    #[test]
    fn empty_text_is_error() {
        assert!(parse_playlist("", BASE).is_err());
        assert!(parse_playlist("   \n\n\t\n", BASE).is_err());
    }

    #[test]
    fn non_m3u_is_error() {
        let err = parse_playlist("#EXTINF:4,\nseg.ts\n", BASE).expect_err("非 M3U 必须报错");
        assert!(err.to_string().contains("EXTM3U"));
        assert!(parse_playlist("hello world", BASE).is_err());
    }

    #[test]
    fn only_extm3u_is_empty_media_playlist() {
        let media = parse_media_only("#EXTM3U\n");
        assert!(media.segments.is_empty());
        assert!(media.init_map.is_none());
        assert!(!media.is_endlist);
    }

    #[test]
    fn extinf_without_uri_is_error() {
        let err = parse_playlist("#EXTM3U\n#EXTINF:4,\n", BASE).expect_err("缺 URI 必须报错");
        assert!(err.to_string().contains("EXTINF"));
        // 后接 ENDLIST 仍未给 URI，同样报错
        assert!(parse_playlist("#EXTM3U\n#EXTINF:4,\n#EXT-X-ENDLIST\n", BASE).is_err());
    }

    #[test]
    fn extinf_followed_by_extinf_is_error() {
        let err = parse_playlist("#EXTM3U\n#EXTINF:4,\n#EXTINF:4,\nseg.ts\n", BASE)
            .expect_err("连续 EXTINF 说明前一个缺 URI，必须报错");
        assert!(err.to_string().contains("EXTINF"));
    }

    #[test]
    fn bare_uri_without_extinf_is_ignored() {
        // 无 EXTINF 前置的裸行按容错口径忽略（不报错、不入列）
        let media = parse_media_only("#EXTM3U\nstray.ts\n#EXTINF:4,\nseg.ts\n");
        assert_eq!(media.segments.len(), 1);
        assert_eq!(
            media.segments[0].uri,
            "https://cdn.example.com/media/seg.ts"
        );
    }

    #[test]
    fn stream_inf_without_uri_is_error() {
        let err = parse_playlist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n", BASE)
            .expect_err("档位缺 URI 必须报错");
        assert!(err.to_string().contains("STREAM-INF"));
    }

    #[test]
    fn stream_inf_without_bandwidth_is_error() {
        assert!(parse_playlist(
            "#EXTM3U\n#EXT-X-STREAM-INF:CODECS=\"mp4a.40.2\"\na.m3u8\n",
            BASE
        )
        .is_err());
    }

    #[test]
    fn malformed_extinf_duration_is_error() {
        assert!(parse_playlist("#EXTM3U\n#EXTINF:abc,\nseg.ts\n", BASE).is_err());
    }

    #[test]
    fn malformed_byterange_is_error() {
        assert!(
            parse_playlist("#EXTM3U\n#EXTINF:4,\n#EXT-X-BYTERANGE:abc\nseg.ts\n", BASE).is_err()
        );
        assert!(parse_playlist(
            "#EXTM3U\n#EXTINF:4,\n#EXT-X-BYTERANGE:100@abc\nseg.ts\n",
            BASE
        )
        .is_err());
    }

    #[test]
    fn malformed_iv_is_error() {
        assert!(parse_playlist(
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k.key\",IV=0xZZ\n#EXTINF:4,\nseg.ts\n",
            BASE
        )
        .is_err());
        assert!(parse_playlist(
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k.key\",IV=0x00112233445566778899AABBCCDDEEFF00\n#EXTINF:4,\nseg.ts\n",
            BASE
        )
        .is_err());
    }

    #[test]
    fn key_without_method_is_error() {
        assert!(parse_playlist(
            "#EXTM3U\n#EXT-X-KEY:URI=\"k.key\"\n#EXTINF:4,\nseg.ts\n",
            BASE
        )
        .is_err());
    }

    #[test]
    fn aes128_key_without_uri_is_error() {
        assert!(parse_playlist(
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128\n#EXTINF:4,\nseg.ts\n",
            BASE
        )
        .is_err());
    }

    #[test]
    fn map_without_uri_is_error() {
        assert!(parse_playlist(
            "#EXTM3U\n#EXT-X-MAP:BYTERANGE=\"10@0\"\n#EXTINF:4,\nseg.m4s\n",
            BASE
        )
        .is_err());
    }

    // ---------- 编码/换行容错 ----------

    #[test]
    fn bom_and_crlf_are_tolerated() {
        let text = "\u{feff}#EXTM3U\r\n#EXT-X-MEDIA-SEQUENCE:0\r\n#EXTINF:4.5,\r\nseg0.ts\r\n#EXT-X-ENDLIST\r\n";
        let media = parse_media_only(text);
        assert_eq!(media.segments.len(), 1);
        assert_eq!(media.segments[0].duration, 4.5);
        assert_eq!(
            media.segments[0].uri,
            "https://cdn.example.com/media/seg0.ts"
        );
        assert!(media.is_endlist);
    }

    #[test]
    fn empty_base_url_keeps_relative_uri() {
        let playlist = parse_playlist("#EXTM3U\n#EXTINF:4,\nseg0.ts\n", "").expect("应成功");
        match playlist {
            Playlist::Media(media) => assert_eq!(media.segments[0].uri, "seg0.ts"),
            Playlist::Master(_) => panic!("预期 media"),
        }
    }

    // ---------- 点段规范化（RFC 3986 §5.2.4） ----------

    #[test]
    fn dot_segments_are_normalized() {
        assert_eq!(
            normalize_dot_segments("https://h.com/a/b/../c.m3u8"),
            "https://h.com/a/c.m3u8"
        );
        assert_eq!(
            normalize_dot_segments("https://h.com/a/./b/./c.m3u8"),
            "https://h.com/a/b/c.m3u8"
        );
        assert_eq!(
            normalize_dot_segments("https://h.com/a/b/../../x.m3u8"),
            "https://h.com/x.m3u8"
        );
        // 不得越过根
        assert_eq!(
            normalize_dot_segments("https://h.com/../x.m3u8"),
            "https://h.com/x.m3u8"
        );
        // query/fragment 保留
        assert_eq!(
            normalize_dot_segments("https://h.com/a/../b.m3u8?token=1#frag"),
            "https://h.com/b.m3u8?token=1#frag"
        );
        // 无需处理时原样返回
        assert_eq!(
            normalize_dot_segments("https://h.com/a/b.m3u8"),
            "https://h.com/a/b.m3u8"
        );
        // 非绝对 URI 原样返回
        assert_eq!(normalize_dot_segments("a/../b.ts"), "a/../b.ts");
    }

    #[test]
    fn media_dot_segment_uris_are_normalized() {
        let media =
            parse_media_only("#EXTM3U\n#EXTINF:4,\n../seg0.ts\n#EXTINF:4,\n./sub/../seg1.ts\n");
        assert_eq!(media.segments[0].uri, "https://cdn.example.com/seg0.ts");
        assert_eq!(
            media.segments[1].uri,
            "https://cdn.example.com/media/seg1.ts"
        );
    }

    #[test]
    fn key_after_map_applies_to_init_map() {
        let text = "\
#EXTM3U
#EXT-X-MAP:URI=\"init.mp4\"
#EXT-X-KEY:METHOD=AES-128,URI=\"k.key\"
#EXTINF:4,
seg0.m4s
";
        let media = parse_media_only(text);
        let map = media.init_map.expect("应有 init map");
        let map_key = map.key.expect("KEY 在 MAP 之后也应生效");
        assert_eq!(map_key.uri, "https://cdn.example.com/media/k.key");
        assert_eq!(map_key.iv, Some(iv_from_sequence(0)));
    }

    // ---------- 属性解析单元测试 ----------

    #[test]
    fn attribute_parser_handles_quoted_commas() {
        let attrs = parse_attributes("BANDWIDTH=128000,CODECS=\"avc1.4d401f,mp4a.40.2\",NAME=x")
            .expect("应成功");
        assert_eq!(
            attrs,
            vec![
                ("BANDWIDTH".to_string(), "128000".to_string()),
                ("CODECS".to_string(), "avc1.4d401f,mp4a.40.2".to_string()),
                ("NAME".to_string(), "x".to_string()),
            ]
        );
    }

    #[test]
    fn attribute_parser_rejects_unclosed_quote() {
        assert!(parse_attributes("CODECS=\"avc1").is_err());
        assert!(parse_attributes("NOEQUALS").is_err());
    }

    #[test]
    fn attribute_parser_allows_empty_input() {
        assert!(parse_attributes("").expect("应成功").is_empty());
    }

    // ---------- 真实夹具 ----------

    /// 批 47 真机 HLS 播放取证夹具（`docs/evidence/batch47/mock_media/hls/playlist.m3u8`
    /// 的原样副本）：4 段 TS、相对 URI、含 `#EXT-X-MEDIA-SEQUENCE` 与 `#EXT-X-ENDLIST`。
    const FIXTURE_MEDIA_BATCH47: &str = include_str!("../../tests/fixtures/hls/media_batch47.m3u8");

    #[test]
    fn real_fixture_batch47_media_playlist() {
        let media = match parse_playlist(
            FIXTURE_MEDIA_BATCH47,
            "http://127.0.0.1:8099/hls/playlist.m3u8",
        )
        .expect("真实夹具应解析成功")
        {
            Playlist::Media(media) => media,
            Playlist::Master(master) => panic!("夹具应为 media，实际 {master:?}"),
        };
        assert!(media.is_endlist);
        assert!(media.init_map.is_none());
        assert_eq!(media.segments.len(), 4);
        let uris: Vec<&str> = media.segments.iter().map(|s| s.uri.as_str()).collect();
        assert_eq!(
            uris,
            vec![
                "http://127.0.0.1:8099/hls/seg_000.ts",
                "http://127.0.0.1:8099/hls/seg_001.ts",
                "http://127.0.0.1:8099/hls/seg_002.ts",
                "http://127.0.0.1:8099/hls/seg_003.ts",
            ]
        );
        assert!((media.segments[0].duration - 4.017056).abs() < 1e-9);
        assert!((media.segments[3].duration - 0.023222).abs() < 1e-9);
        assert!(media.segments.iter().all(|s| s.key.is_none()));
    }

    /// 真实形态的 master 夹具（多码率 + 纯音频档 + 相对路径）
    const FIXTURE_MASTER: &str = include_str!("../../tests/fixtures/hls/master.m3u8");

    #[test]
    fn real_fixture_master_selects_audio() {
        let master = match parse_playlist(FIXTURE_MASTER, "https://live.example.com/vod/index.m3u8")
            .expect("master 夹具应解析成功")
        {
            Playlist::Master(master) => master,
            Playlist::Media(media) => panic!("夹具应为 master，实际 {media:?}"),
        };
        // I-FRAME-STREAM-INF 不是档位（不同标签，忽略），故只有 3 个 variant
        assert_eq!(master.variants.len(), 3);
        let picked = select_variant(&master).expect("应有选中档位");
        assert_eq!(picked.uri, "https://live.example.com/vod/audio/index.m3u8");
        assert_eq!(picked.bandwidth, 128_000);
    }

    /// 真实形态的加密 fMP4 media 夹具（AES-128 + MAP + BYTERANGE + DISCONTINUITY）
    const FIXTURE_ENCRYPTED_FMP4: &str =
        include_str!("../../tests/fixtures/hls/media_encrypted_fmp4.m3u8");

    #[test]
    fn real_fixture_encrypted_fmp4_media() {
        let media = match parse_playlist(
            FIXTURE_ENCRYPTED_FMP4,
            "https://vod.example.com/movie/index.m3u8",
        )
        .expect("加密 fMP4 夹具应解析成功")
        {
            Playlist::Media(media) => media,
            Playlist::Master(master) => panic!("夹具应为 media，实际 {master:?}"),
        };
        assert!(media.is_endlist);
        let map = media.init_map.expect("应有 init map");
        assert_eq!(map.uri, "https://vod.example.com/movie/init.mp4");
        assert_eq!(
            map.byte_range,
            Some(ByteRange {
                length: 720,
                offset: 0
            })
        );
        assert_eq!(
            map.key.as_ref().map(|k| k.uri.as_str()),
            Some("https://vod.example.com/movie/key.bin")
        );

        assert_eq!(media.segments.len(), 4);
        // 第一段显式 IV
        assert_eq!(
            media.segments[0].key.as_ref().and_then(|k| k.iv),
            Some([
                0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
                0xee, 0xff
            ])
        );
        // 第二段仍用同一 EXT-X-KEY（含显式 IV）→ 沿用该 IV，不按序列号推算
        assert_eq!(
            media.segments[1].key.as_ref().and_then(|k| k.iv),
            Some([
                0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
                0xee, 0xff
            ])
        );
        // BYTERANGE：首段显式，后续续接
        assert_eq!(
            media.segments[0].byte_range,
            Some(ByteRange {
                length: 1000,
                offset: 0
            })
        );
        assert_eq!(
            media.segments[1].byte_range,
            Some(ByteRange {
                length: 1200,
                offset: 1000
            })
        );
        assert_eq!(
            media.segments[2].byte_range,
            Some(ByteRange {
                length: 800,
                offset: 2200
            })
        );
        assert_eq!(media.segments[3].byte_range, None);
        // 第三段起换 key2（无 IV）→ 按媒体序列号续算
        assert_eq!(
            media.segments[2].key.as_ref().map(|k| k.uri.as_str()),
            Some("https://vod.example.com/movie/key2.bin")
        );
        assert_eq!(
            media.segments[2].key.as_ref().and_then(|k| k.iv),
            Some(iv_from_sequence(12))
        );
        // 第三段前有 DISCONTINUITY
        assert!(!media.segments[1].discontinuity);
        assert!(media.segments[2].discontinuity);
        assert!(!media.segments[3].discontinuity);
    }
}
