//! 纯 Rust TTF 字体解析（字体反爬）
//!
//! 逐表对齐 Kotlin/Java 端 `io.legado.app.model.analyzeRule.QueryTTF` 的语义：
//!
//! - cmap 表（format 0 / 4 / 6）→ `unicode → glyphId` 映射（多子表按记录顺序、先到先得）
//! - loca + maxp + glyf 表 → 字形轮廓签名（简单字形为相对坐标序列，复合字形为组件描述）
//! - 最终建立 `unicode → 轮廓签名` 与 `轮廓签名 → unicode` 双向映射，
//!   供 [`super::font_api::replace_font`] 在错误字体与正确字体之间按轮廓反查字符。
//!
//! 说明：防爬字体的核心是 cmap 被重新洗牌，字符的**轮廓数据不变**，
//! 因此替换必须经由"轮廓签名"对齐两个字体，而非直接映射码点。
//! 这也是不采用 `ttf-parser` 的原因：其 cmap 只暴露单一"最优"子表（原版为多子表合并），
//! 且不暴露可用于签名比对的原始轮廓增量序列。

use std::collections::HashMap;

/// TTF 解析错误（字体损坏 / 缺表 / 越界）
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TtfError {
    /// 数据长度不足（附所需偏移与长度描述）
    Truncated(&'static str),
    /// 缺少必要的表（cmap / glyf / head / loca / maxp）
    MissingTable(&'static str),
}

impl std::fmt::Display for TtfError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TtfError::Truncated(what) => write!(f, "TTF 数据截断: {}", what),
            TtfError::MissingTable(tag) => write!(f, "TTF 缺少 {} 表", tag),
        }
    }
}

impl std::error::Error for TtfError {}

/// 大端字节读取器（带边界检查，对应 Java 端 BufferReader）
struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }

    fn seek(&mut self, pos: usize) -> Result<(), TtfError> {
        if pos > self.buf.len() {
            return Err(TtfError::Truncated("seek"));
        }
        self.pos = pos;
        Ok(())
    }

    fn remaining(&self) -> usize {
        self.buf.len().saturating_sub(self.pos)
    }

    fn ensure(&self, n: usize) -> Result<(), TtfError> {
        if self.remaining() < n {
            return Err(TtfError::Truncated("read"));
        }
        Ok(())
    }

    fn read_u8(&mut self) -> Result<u8, TtfError> {
        self.ensure(1)?;
        let v = self.buf[self.pos];
        self.pos += 1;
        Ok(v)
    }

    fn read_u16(&mut self) -> Result<u16, TtfError> {
        self.ensure(2)?;
        let v = u16::from_be_bytes([self.buf[self.pos], self.buf[self.pos + 1]]);
        self.pos += 2;
        Ok(v)
    }

    fn read_i16(&mut self) -> Result<i16, TtfError> {
        self.ensure(2)?;
        let v = i16::from_be_bytes([self.buf[self.pos], self.buf[self.pos + 1]]);
        self.pos += 2;
        Ok(v)
    }

    fn read_u32(&mut self) -> Result<u32, TtfError> {
        self.ensure(4)?;
        let v = u32::from_be_bytes([
            self.buf[self.pos],
            self.buf[self.pos + 1],
            self.buf[self.pos + 2],
            self.buf[self.pos + 3],
        ]);
        self.pos += 4;
        Ok(v)
    }

    fn read_tag(&mut self) -> Result<[u8; 4], TtfError> {
        self.ensure(4)?;
        let mut tag = [0u8; 4];
        tag.copy_from_slice(&self.buf[self.pos..self.pos + 4]);
        self.pos += 4;
        Ok(tag)
    }

    fn read_u16_vec(&mut self, len: usize) -> Result<Vec<u16>, TtfError> {
        let mut out = Vec::with_capacity(len);
        for _ in 0..len {
            out.push(self.read_u16()?);
        }
        Ok(out)
    }

    fn read_i16_vec(&mut self, len: usize) -> Result<Vec<i16>, TtfError> {
        let mut out = Vec::with_capacity(len);
        for _ in 0..len {
            out.push(self.read_i16()?);
        }
        Ok(out)
    }
}

/// 简单字形轮廓数据（相对坐标增量序列，对应 Java GlyphTableBySimple）
#[derive(Debug, Clone)]
struct SimpleGlyph {
    x: Vec<i32>,
    y: Vec<i32>,
}

/// 复合字形组件（对应 Java GlyphTableComponent）
#[derive(Debug, Clone)]
struct CompositeComponent {
    flags: u16,
    glyph_index: u16,
    arg1: i32,
    arg2: i32,
    x_scale: f32,
    scale01: f32,
    scale10: f32,
    y_scale: f32,
}

/// 字形轮廓（对应 Java GlyfLayout）
#[derive(Debug, Clone)]
enum Glyph {
    /// 简单字形（numberOfContours >= 0）
    Simple(SimpleGlyph),
    /// 复合字形（numberOfContours < 0）
    Composite(Vec<CompositeComponent>),
}

/// TTF 字体解析结果（对应 Java QueryTTF）
#[derive(Clone)]
pub struct QueryTtf {
    /// unicode → glyphId（cmap 解析所得，对应 Java unicodeToGlyphId）
    unicode_to_glyph_id: HashMap<u32, u32>,
    /// unicode → 轮廓签名（对应 Java unicodeToGlyph）
    unicode_to_glyph: HashMap<u32, String>,
    /// 轮廓签名 → unicode（对应 Java glyphToUnicode，先到先得）
    glyph_to_unicode: HashMap<String, u32>,
}

impl QueryTtf {
    /// 解析 TTF 字体二进制，对应 Java `QueryTTF(byte[] buffer)` 构造流程
    pub fn parse(buf: &[u8]) -> Result<Self, TtfError> {
        let mut r = Reader::new(buf);
        let _sfnt_version = r.read_u32()?;
        let num_tables = r.read_u16()? as usize;
        let _search_range = r.read_u16()?;
        let _entry_selector = r.read_u16()?;
        let _range_shift = r.read_u16()?;

        // 读表目录
        let mut tables: HashMap<[u8; 4], (usize, usize)> = HashMap::new();
        for _ in 0..num_tables {
            let tag = r.read_tag()?;
            let _checksum = r.read_u32()?;
            let offset = r.read_u32()? as usize;
            let length = r.read_u32()? as usize;
            tables.insert(tag, (offset, length));
        }

        // head：indexToLocFormat
        let (head_off, _head_len) = *tables.get(b"head").ok_or(TtfError::MissingTable("head"))?;
        let index_to_loc_format = {
            r.seek(head_off + 50)?;
            r.read_i16()?
        };

        // maxp：numGlyphs / maxContours
        let (maxp_off, _) = *tables.get(b"maxp").ok_or(TtfError::MissingTable("maxp"))?;
        let (num_glyphs, max_contours) = {
            r.seek(maxp_off)?;
            let _version = r.read_u32()?;
            let num_glyphs = r.read_u16()? as usize;
            let _max_points = r.read_u16()?;
            let max_contours = r.read_u16()? as i32;
            (num_glyphs, max_contours)
        };

        // loca：glyphId → glyf 偏移
        let (loca_off, loca_len) = *tables.get(b"loca").ok_or(TtfError::MissingTable("loca"))?;
        let mut loca: Vec<usize> = Vec::new();
        {
            r.seek(loca_off)?;
            if index_to_loc_format == 0 {
                // Offset16：存储值需翻倍
                for _ in 0..(loca_len / 2) {
                    loca.push(r.read_u16()? as usize * 2);
                }
            } else {
                for _ in 0..(loca_len / 4) {
                    loca.push(r.read_u32()? as usize);
                }
            }
        }

        // cmap：unicode → glyphId（多子表按记录顺序处理，先到先得）
        let (cmap_off, _) = *tables.get(b"cmap").ok_or(TtfError::MissingTable("cmap"))?;
        let unicode_to_glyph_id = parse_cmap(buf, cmap_off)?;

        // glyf：glyphId → 轮廓数据
        let (glyf_off, _) = *tables.get(b"glyf").ok_or(TtfError::MissingTable("glyf"))?;
        let glyphs = parse_glyf(buf, glyf_off, &loca, num_glyphs, max_contours)?;

        // 建立 unicode ↔ 轮廓签名双向映射（对应 Java 构造尾部循环）
        let glyph_count = glyphs.len();
        let mut unicode_to_glyph: HashMap<u32, String> = HashMap::new();
        let mut glyph_to_unicode: HashMap<String, u32> = HashMap::new();
        for (&code, &glyph_id) in &unicode_to_glyph_id {
            if glyph_id as usize >= glyph_count {
                continue;
            }
            if let Some(sig) = glyph_signature(&glyphs[glyph_id as usize]) {
                // Java 端 HashMap.put：同 unicode 以最后一次为准；
                // 同签名反查 unicode 采用先到先得（entry 语义对齐原版行为意图）
                unicode_to_glyph.insert(code, sig.clone());
                glyph_to_unicode.entry(sig).or_insert(code);
            }
        }

        Ok(QueryTtf {
            unicode_to_glyph_id,
            unicode_to_glyph,
            glyph_to_unicode,
        })
    }

    /// 使用 Unicode 值查询轮廓签名（对应 `getGlyfByUnicode`）
    pub fn glyf_by_unicode(&self, code: u32) -> Option<&String> {
        self.unicode_to_glyph.get(&code)
    }

    /// 使用 Unicode 值查询轮廓索引，找不到返回 0（对应 `getGlyfIdByUnicode`）
    pub fn glyf_id_by_unicode(&self, code: u32) -> u32 {
        self.unicode_to_glyph_id.get(&code).copied().unwrap_or(0)
    }

    /// 使用轮廓签名反查 Unicode，找不到返回 0（对应 `getUnicodeByGlyf`）
    pub fn unicode_by_glyf(&self, glyf: &str) -> u32 {
        self.glyph_to_unicode.get(glyf).copied().unwrap_or(0)
    }

    /// Unicode 空白字符判断（对应 `isBlankUnicode`，白名单与 Java 端逐项一致）
    pub fn is_blank_unicode(code: u32) -> bool {
        matches!(
            code,
            0x0009
                | 0x0020
                | 0x00A0
                | 0x2002
                | 0x2003
                | 0x2007
                | 0x200A
                | 0x200B
                | 0x200C
                | 0x200D
                | 0x202F
                | 0x205F
        )
    }
}

/// 解析 cmap 表，返回 unicode → glyphId 映射
///
/// 支持 format 0 / 4 / 6（与 Java 端一致）；多个编码子表按记录顺序处理，
/// 同一 unicode 先到先得（Java 端 put 的确定性等价语义）。
fn parse_cmap(buf: &[u8], cmap_off: usize) -> Result<HashMap<u32, u32>, TtfError> {
    let mut r = Reader::new(buf);
    r.seek(cmap_off)?;
    let _version = r.read_u16()?;
    let num_tables = r.read_u16()? as usize;

    let mut subtable_offsets: Vec<usize> = Vec::with_capacity(num_tables);
    for _ in 0..num_tables {
        let _platform_id = r.read_u16()?;
        let _encoding_id = r.read_u16()?;
        let offset = r.read_u32()? as usize;
        subtable_offsets.push(offset);
    }

    let mut map: HashMap<u32, u32> = HashMap::new();
    let mut seen: std::collections::HashSet<usize> = std::collections::HashSet::new();
    for &sub_off in &subtable_offsets {
        if !seen.insert(sub_off) {
            continue; // 同一子表只处理一次（对应 Java tables.containsKey 跳过）
        }
        r.seek(cmap_off + sub_off)?;
        let format = r.read_u16()?;
        let length = r.read_u16()? as usize;
        let _language = r.read_u16()?;
        match format {
            0 => {
                // 字节编码表：glyphIdArray[unicode] = glyphId
                let count = length.saturating_sub(6);
                for unicode in 0..count {
                    let glyph_id = r.read_u8()? as u32;
                    if glyph_id == 0 {
                        continue; // 排除轮廓索引为 0 的 Unicode
                    }
                    map.entry(unicode as u32).or_insert(glyph_id);
                }
            }
            4 => {
                let seg_count_x2 = r.read_u16()? as usize;
                let seg_count = seg_count_x2 / 2;
                let _search_range = r.read_u16()?;
                let _entry_selector = r.read_u16()?;
                let _range_shift = r.read_u16()?;
                let end_code = r.read_u16_vec(seg_count)?;
                let _reserved_pad = r.read_u16()?;
                let start_code = r.read_u16_vec(seg_count)?;
                let id_delta = r.read_i16_vec(seg_count)?;
                let id_range_offsets = r.read_u16_vec(seg_count)?;
                let glyph_id_array_len =
                    length.saturating_sub(16 + seg_count * 8).saturating_div(2);
                let glyph_id_array = r.read_u16_vec(glyph_id_array_len)?;

                for seg in 0..seg_count {
                    let start = start_code[seg] as u32;
                    let end = end_code[seg] as u32;
                    let delta = id_delta[seg] as i32;
                    let range_offset = id_range_offsets[seg];
                    for unicode in start..=end {
                        let glyph_id: i64 = if range_offset == 0 {
                            ((unicode as i32).wrapping_add(delta)) as u16 as i64
                        } else {
                            // Java 端索引公式（含越界跳过语义）
                            let g_index = (range_offset / 2) as i64 + unicode as i64 - start as i64
                                + seg as i64
                                - seg_count as i64;
                            if g_index < 0 || g_index >= glyph_id_array_len as i64 {
                                continue; // 轮廓索引为 0，排除
                            }
                            glyph_id_array[g_index as usize] as i64 + delta as i64
                        };
                        if glyph_id == 0 {
                            continue; // 排除轮廓索引为 0 的 Unicode
                        }
                        map.entry(unicode).or_insert(glyph_id as u32);
                    }
                }
            }
            6 => {
                let first_code = r.read_u16()? as u32;
                let entry_count = r.read_u16()? as usize;
                for i in 0..entry_count {
                    let glyph_id = r.read_u16()? as u32;
                    map.entry(first_code + i as u32).or_insert(glyph_id);
                }
            }
            _ => {
                // 其余 format（2/8/10/12/13/14）原版未支持，跳过
            }
        }
    }
    Ok(map)
}

/// 解析 glyf 表（经由 loca 偏移），返回 glyphId → 轮廓数据
fn parse_glyf(
    buf: &[u8],
    glyf_off: usize,
    loca: &[usize],
    num_glyphs: usize,
    max_contours: i32,
) -> Result<Vec<Option<Glyph>>, TtfError> {
    let mut glyphs: Vec<Option<Glyph>> = vec![None; num_glyphs];
    if loca.len() < num_glyphs + 1 {
        return Ok(glyphs); // loca 与 maxp 不一致时保持缺失字形
    }
    let mut r = Reader::new(buf);
    for index in 0..num_glyphs {
        if loca[index] == loca[index + 1] {
            continue; // 当前 loca 与下一个相同，字形不存在
        }
        r.seek(glyf_off + loca[index])?;
        let number_of_contours = r.read_i16()?;
        if number_of_contours as i32 > max_contours {
            continue; // 轮廓数超过 maxp 声明，字形无效
        }
        let _x_min = r.read_i16()?;
        let _y_min = r.read_i16()?;
        let _x_max = r.read_i16()?;
        let _y_max = r.read_i16()?;

        if number_of_contours == 0 {
            // 轮廓数为 0 时无轮廓数据（签名保留为空字符串）
            glyphs[index] = Some(Glyph::Simple(SimpleGlyph {
                x: Vec::new(),
                y: Vec::new(),
            }));
            continue;
        }

        if number_of_contours > 0 {
            glyphs[index] = Some(Glyph::Simple(parse_simple_glyph(
                &mut r,
                number_of_contours,
            )?));
        } else {
            glyphs[index] = Some(Glyph::Composite(parse_composite_glyph(&mut r)?));
        }
    }
    Ok(glyphs)
}

/// 解析简单字形（flags + x/y 相对坐标增量），对应 Java 端简单轮廓分支
fn parse_simple_glyph(
    r: &mut Reader<'_>,
    number_of_contours: i16,
) -> Result<SimpleGlyph, TtfError> {
    let end_pts = r.read_u16_vec(number_of_contours as usize)?;
    let instruction_length = r.read_u16()? as usize;
    // 跳过指令数据
    r.ensure(instruction_length)?;
    r.seek(r.pos + instruction_length)?;

    let flag_length = end_pts.last().copied().unwrap_or(0) as usize + 1;

    // 轮廓点描述标志（含 bit3 重复展开）
    let mut flags: Vec<u8> = Vec::with_capacity(flag_length);
    while flags.len() < flag_length {
        let flag = r.read_u8()?;
        flags.push(flag);
        if flag & 0x08 == 0x08 {
            let repeat = r.read_u8()?;
            for _ in 0..repeat {
                flags.push(flag);
            }
        }
    }
    flags.truncate(flag_length);

    // x 轴相对值
    let mut x = Vec::with_capacity(flag_length);
    for &flag in &flags {
        match flag & 0x12 {
            0x02 => x.push(-(r.read_u8()? as i32)),
            0x12 => x.push(r.read_u8()? as i32),
            0x10 => x.push(0), // 点位数据重复上一次，相对变化量为 0
            _ => x.push(r.read_i16()? as i32),
        }
    }

    // y 轴相对值
    let mut y = Vec::with_capacity(flag_length);
    for &flag in &flags {
        match flag & 0x24 {
            0x04 => y.push(-(r.read_u8()? as i32)),
            0x24 => y.push(r.read_u8()? as i32),
            0x20 => y.push(0),
            _ => y.push(r.read_i16()? as i32),
        }
    }

    Ok(SimpleGlyph { x, y })
}

/// 解析复合字形组件序列，对应 Java 端复合轮廓分支
fn parse_composite_glyph(r: &mut Reader<'_>) -> Result<Vec<CompositeComponent>, TtfError> {
    let mut components = Vec::new();
    loop {
        let flags = r.read_u16()?;
        let glyph_index = r.read_u16()?;
        let (arg1, arg2): (i32, i32) = match flags & 0b11 {
            0b00 => (r.read_u8()? as i32, r.read_u8()? as i32),
            0b10 => (r.read_u8()? as i8 as i32, r.read_u8()? as i8 as i32),
            0b01 => (r.read_u16()? as i32, r.read_u16()? as i32),
            _ => (r.read_i16()? as i32, r.read_i16()? as i32),
        };
        let mut c = CompositeComponent {
            flags,
            glyph_index,
            arg1,
            arg2,
            x_scale: 0.0,
            scale01: 0.0,
            scale10: 0.0,
            y_scale: 0.0,
        };
        // F2DOT14 缩放数据（/16384.0，与 Java 端一致）
        match flags & 0b1100_1000 {
            0b0000_1000 => {
                let s = r.read_u16()? as f32 / 16384.0;
                c.x_scale = s;
                c.y_scale = s;
            }
            0b0100_0000 => {
                c.x_scale = r.read_u16()? as f32 / 16384.0;
                c.y_scale = r.read_u16()? as f32 / 16384.0;
            }
            0b1000_0000 => {
                c.x_scale = r.read_u16()? as f32 / 16384.0;
                c.scale01 = r.read_u16()? as f32 / 16384.0;
                c.scale10 = r.read_u16()? as f32 / 16384.0;
                c.y_scale = r.read_u16()? as f32 / 16384.0;
            }
            _ => {}
        }
        let has_more = flags & 0x20 != 0;
        components.push(c);
        if !has_more {
            break;
        }
    }
    Ok(components)
}

/// 计算字形轮廓签名（对应 Java getGlyfById）
///
/// - 简单字形：`"x,y|x,y|..."` 相对坐标序列
/// - 复合字形：`"[{flags:..,glyphIndex:..,...},...]"` 组件描述
///
/// 签名只含**相对**几何信息，防爬字体与其对应正常字体的同一字符签名一致，
/// 因此可作为跨字体字符对齐的依据。
fn glyph_signature(glyph: &Option<Glyph>) -> Option<String> {
    let glyph = glyph.as_ref()?;
    match glyph {
        Glyph::Simple(s) => {
            let coords: Vec<String> =
                s.x.iter()
                    .zip(s.y.iter())
                    .map(|(x, y)| format!("{},{}", x, y))
                    .collect();
            Some(coords.join("|"))
        }
        Glyph::Composite(list) => {
            let parts: Vec<String> = list
                .iter()
                .map(|g| {
                    format!(
                        "{{flags:{},glyphIndex:{},arg1:{},arg2:{},xScale:{},scale01:{},scale10:{},yScale:{}}}",
                        g.flags, g.glyph_index, g.arg1, g.arg2, g.x_scale, g.scale01, g.scale10, g.y_scale
                    )
                })
                .collect();
            Some(format!("[{}]", parts.join(",")))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host_api::font_api::tests::{build_minimal_ttf, Segment};

    /// 错误字体映射：PUA E001..E003 → glyph 1..3（delta 取模运算正值）
    fn error_segments() -> Vec<Segment> {
        vec![Segment {
            start: 0xE001,
            end: 0xE003,
            id_delta: 0x2000,
        }]
    }

    /// 正确字体映射：'A'..='C' → glyph 1..3
    fn correct_segments() -> Vec<Segment> {
        vec![Segment {
            start: 0x41,
            end: 0x43,
            id_delta: -0x40,
        }]
    }

    #[test]
    fn test_parse_minimal_ttf_cmap() {
        let font = build_minimal_ttf(&error_segments(), false);
        let ttf = QueryTtf::parse(&font).expect("最小 TTF 应可解析");
        assert_eq!(ttf.glyf_id_by_unicode(0xE001), 1);
        assert_eq!(ttf.glyf_id_by_unicode(0xE002), 2);
        assert_eq!(ttf.glyf_id_by_unicode(0xE003), 3);
        assert_eq!(ttf.glyf_id_by_unicode(0x0041), 0); // 未映射返回 0
    }

    #[test]
    fn test_glyph_signatures_distinct() {
        let err = QueryTtf::parse(&build_minimal_ttf(&error_segments(), false)).unwrap();
        let ok = QueryTtf::parse(&build_minimal_ttf(&correct_segments(), false)).unwrap();
        // 同字形索引在两字体中签名一致（防爬替换的前提）
        assert_eq!(err.glyf_by_unicode(0xE001), ok.glyf_by_unicode(0x41));
        // 不同字形签名不同
        assert_ne!(err.glyf_by_unicode(0xE001), err.glyf_by_unicode(0xE002));
        // 签名反查 unicode
        let sig = ok.glyf_by_unicode(0x41).cloned().unwrap();
        assert_eq!(ok.unicode_by_glyf(&sig), 0x41);
    }

    #[test]
    fn test_composite_glyph_signature() {
        let font = build_minimal_ttf(&correct_segments(), true);
        let ttf = QueryTtf::parse(&font).expect("含复合字形的 TTF 应可解析");
        // glyph 1 为复合字形，签名以 "[" 开头
        let sig = ttf.glyf_by_unicode(0x41).cloned().unwrap();
        assert!(sig.starts_with("[{flags:"));
    }

    #[test]
    fn test_is_blank_unicode() {
        assert!(QueryTtf::is_blank_unicode(0x20));
        assert!(QueryTtf::is_blank_unicode(0x200B));
        assert!(!QueryTtf::is_blank_unicode(0x41));
    }

    #[test]
    fn test_parse_truncated_font_fails() {
        let font = build_minimal_ttf(&error_segments(), false);
        assert!(QueryTtf::parse(&font[..10]).is_err());
    }

    #[test]
    fn test_format0_cmap() {
        // 直接构造 format 0 子表并解析
        let mut sub = Vec::new();
        sub.extend_from_slice(&0u16.to_be_bytes()); // format
        sub.extend_from_slice(&262u16.to_be_bytes()); // length = 6 + 256
        sub.extend_from_slice(&0u16.to_be_bytes()); // language
        for i in 0..256u16 {
            sub.push(if i == 0x41 { 5 } else { 0 }); // 'A' → glyph 5
        }
        let mut cmap_table = Vec::new();
        cmap_table.extend_from_slice(&0u16.to_be_bytes()); // version
        cmap_table.extend_from_slice(&1u16.to_be_bytes()); // numTables
        cmap_table.extend_from_slice(&1u16.to_be_bytes()); // platform
        cmap_table.extend_from_slice(&0u16.to_be_bytes()); // encoding
        cmap_table.extend_from_slice(&12u32.to_be_bytes()); // offset
        cmap_table.extend_from_slice(&sub);
        let map = parse_cmap(&cmap_table, 0).unwrap();
        assert_eq!(map.get(&0x41), Some(&5u32));
        assert!(!map.contains_key(&0x42)); // glyphId=0 被排除
    }
}
