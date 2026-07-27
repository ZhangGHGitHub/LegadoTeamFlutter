//! 段落重排算法
//! 移植自 Kotlin ContentHelp.kt (630行)
//! 纯文本处理，零平台依赖
//!
//! 核心功能：
//! - 合并过短段落（避免一句一段）
//! - 对话模式检测（引号配对）
//! - 强制切分过长段落
//! - 保持语义完整性

/// 句子结尾标点（不含引号，因引号可能误判）
const MARK_SENTENCES_END: &str = "？。！?!~";

/// 句子结尾标点（含英文句点）
const MARK_SENTENCES_END_P: &str = ".？。！?!~";

/// 句中标点
#[allow(dead_code)]
const MARK_SENTENCES_MID: &str = ".，、,—…";

/// 说话动词
#[allow(dead_code)]
const MARK_SENTENCES_SAY: &str = "问说喊唱叫骂道着答";

/// 引号前的标点（XXX说："）
const MARK_QUOTATION_BEFORE: &str = "，：,:";

/// 引号字符集
const MARK_QUOTATION: &str = "\"\u{201C}\u{201D}";

/// 右引号字符集
const MARK_QUOTATION_RIGHT: &str = "\"\u{201D}";

/// 字典词条最大长度
const WORD_MAX_LENGTH: usize = 16;

/// 段落重排主函数
///
/// 对章节内容进行智能重排：
/// 1. 合并过短段落（避免一句一段）
/// 2. 对话模式检测（引号配对）
/// 3. 强制切分过长段落
/// 4. 保持语义完整性
pub fn re_segment(content: &str, chapter_name: &str) -> String {
    let lines: Vec<&str> = content.lines().collect();
    if lines.is_empty() {
        return String::new();
    }

    let mut result = Vec::new();
    let mut current_paragraph = String::new();

    for line in &lines {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            if !current_paragraph.is_empty() {
                result.push(current_paragraph.clone());
                current_paragraph.clear();
            }
            continue;
        }

        // 跳过章节标题行
        if trimmed == chapter_name.trim() && current_paragraph.is_empty() && result.is_empty() {
            continue;
        }

        // 检查是否是新的段落开始
        if should_start_new_paragraph(trimmed, &current_paragraph) {
            if !current_paragraph.is_empty() {
                result.push(current_paragraph.clone());
            }
            current_paragraph = trimmed.to_string();
        } else {
            // 合并到当前段落
            if !current_paragraph.is_empty() {
                current_paragraph.push_str(trimmed);
            } else {
                current_paragraph = trimmed.to_string();
            }
        }
    }

    if !current_paragraph.is_empty() {
        result.push(current_paragraph);
    }

    // 后处理：合并过短段落 + 切分过长段落
    let result = merge_short_paragraphs(result);
    let result = split_long_paragraphs(result);
    let result = balance_quotes(result);

    result.join("\n\n")
}

/// 判断是否应开始新段落
fn should_start_new_paragraph(line: &str, current: &str) -> bool {
    if current.is_empty() {
        return false;
    }
    // 以引号开头的对话
    if starts_with_quote(line) {
        return true;
    }
    // 以感叹号/问号/右引号结尾的对话
    if let Some(last_char) = current.chars().last() {
        if MARK_SENTENCES_END.contains(last_char) || MARK_QUOTATION_RIGHT.contains(last_char) {
            return true;
        }
    }
    // 当前段落已足够长（按字符数计算）
    if current.chars().count() > 200 {
        return true;
    }
    false
}

/// 检测引号开头
fn starts_with_quote(line: &str) -> bool {
    line.starts_with('\u{201C}') // "
        || line.starts_with('\u{201D}') // "
        || line.starts_with('\u{300C}') // 「
        || line.starts_with('\u{300E}') // 『
        || line.starts_with('"')
}

/// 合并过短段落（< 10 字符的段落与前一段合并）
fn merge_short_paragraphs(paragraphs: Vec<String>) -> Vec<String> {
    let mut result: Vec<String> = Vec::new();
    for p in paragraphs {
        if p.chars().count() < 10 && !starts_with_quote(&p) {
            if let Some(last) = result.last_mut() {
                last.push_str(&p);
                continue;
            }
        }
        result.push(p);
    }
    result
}

/// 切分过长段落（> 500 字符的段落在句号处切分）
fn split_long_paragraphs(paragraphs: Vec<String>) -> Vec<String> {
    let mut result: Vec<String> = Vec::new();
    for p in paragraphs {
        if p.chars().count() > 500 {
            let split = split_at_sentence(&p);
            result.extend(split);
        } else {
            result.push(p);
        }
    }
    result
}

/// 在句号处切分
fn split_at_sentence(text: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();

    for ch in text.chars() {
        current.push(ch);
        if MARK_SENTENCES_END_P.contains(ch) && current.chars().count() > 100 {
            result.push(current.clone());
            current.clear();
        }
    }
    if !current.is_empty() {
        if let Some(last) = result.last_mut() {
            last.push_str(&current);
        } else {
            result.push(current);
        }
    }
    result
}

/// 引号平衡：确保每个开引号有对应的闭引号
fn balance_quotes(paragraphs: Vec<String>) -> Vec<String> {
    paragraphs
        .into_iter()
        .map(|p| {
            let open_count = p.chars().filter(|c| *c == '\u{201C}' || *c == '"').count();
            let close_count = p.chars().filter(|c| *c == '\u{201D}' || *c == '"').count();
            if open_count > close_count {
                format!("{}\u{201D}", p)
            } else {
                p
            }
        })
        .collect()
}

/// 减少段落数量（合并相邻的短段落到目标数量）
pub fn reduce_length(paragraphs: &[String], target: usize) -> Vec<String> {
    if paragraphs.len() <= target || target == 0 {
        return paragraphs.to_vec();
    }
    let chunk_size = paragraphs.len().div_ceil(target);
    paragraphs
        .chunks(chunk_size.max(1))
        .map(|chunk| chunk.join(""))
        .collect()
}

/// 从字符串提取引号包围且不止出现一次的内容为字典
///
/// 移植自 Kotlin makeDict：提取重复出现的引号内词条，
/// 用于避免在字典词条后方插入不必要的换行。
pub fn make_dict(content: &str) -> Vec<String> {
    let mut cache: Vec<String> = Vec::new();
    let mut dict: Vec<String> = Vec::new();

    let chars: Vec<char> = content.chars().collect();
    let len = chars.len();
    let mut i = 0;

    while i < len {
        // 寻找开引号
        if is_open_quote(chars[i]) {
            let start = i + 1;
            let mut j = start;
            // 寻找闭引号
            while j < len && !is_close_quote(chars[j]) && !is_open_quote(chars[j]) {
                // 词条内不含标点
                if is_punctuation(chars[j]) {
                    break;
                }
                j += 1;
            }
            if j < len && is_close_quote(chars[j]) {
                let word_len = j - start;
                if (1..=WORD_MAX_LENGTH).contains(&word_len) {
                    let word: String = chars[start..j].iter().collect();
                    if cache.contains(&word) {
                        if !dict.contains(&word) {
                            dict.push(word);
                        }
                    } else {
                        cache.push(word);
                    }
                }
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
    dict
}

/// 判断是否为开引号
fn is_open_quote(c: char) -> bool {
    c == '\u{201C}' || c == '"' || c == '\u{300C}' || c == '\u{300E}'
}

/// 判断是否为闭引号
fn is_close_quote(c: char) -> bool {
    c == '\u{201D}' || c == '"' || c == '\u{300D}' || c == '\u{300F}'
}

/// 判断是否为标点符号（中日韩常见标点）
fn is_punctuation(c: char) -> bool {
    matches!(
        c,
        '。' | '，'
            | '、'
            | '；'
            | '：'
            | '？'
            | '！'
            | '…'
            | '—'
            | '·'
            | '（'
            | '）'
            | '《'
            | '》'
            | '.'
            | ','
            | ';'
            | ':'
            | '?'
            | '!'
            | '('
            | ')'
            | '['
            | ']'
            | '{'
            | '}'
    )
}

/// 对话模式检测：判断段落是否为纯对话段落（"xxx"形式）
fn is_dialogue_paragraph(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.len() < 3 {
        return false;
    }
    let chars: Vec<char> = trimmed.chars().collect();
    let first = chars[0];
    let last = chars[chars.len() - 1];
    // 以引号开头且以引号结尾，中间无引号
    if (is_open_quote(first) || first == '"') && (is_close_quote(last) || last == '"') {
        let inner = &trimmed[trimmed.chars().next().unwrap().len_utf8()
            ..trimmed.len() - trimmed.chars().last().unwrap().len_utf8()];
        !inner.contains('\u{201C}') && !inner.contains('\u{201D}') && !inner.contains('"')
    } else {
        false
    }
}

/// 强制切分进入对话模式后，未构成 "xxx" 形式的段落
///
/// 移植自 Kotlin splitQuote：在引号位置进行切分
pub fn split_quote(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let length = chars.len();
    if length < 3 {
        return text.to_string();
    }

    if MARK_QUOTATION.contains(chars[0]) {
        // 从前往后找下一个引号
        if let Some(pos) = seek_index(text, MARK_QUOTATION, 1, length - 2, true) {
            let i = pos + 1;
            if i > 1 && i < length && !MARK_QUOTATION_BEFORE.contains(chars[i - 1]) {
                let byte_pos: usize = chars[..i].iter().map(|c| c.len_utf8()).sum();
                return format!("{}\n{}", &text[..byte_pos], &text[byte_pos..]);
            }
        }
    } else if MARK_QUOTATION.contains(chars[length - 1]) {
        // 从后往前找引号
        if let Some(dist) = seek_index(text, MARK_QUOTATION, 1, length - 2, false) {
            let i = length - 1 - dist;
            if i > 1 && i < length && !MARK_QUOTATION_BEFORE.contains(chars[i - 1]) {
                let byte_pos: usize = chars[..i].iter().map(|c| c.len_utf8()).sum();
                return format!("{}\n{}", &text[..byte_pos], &text[byte_pos..]);
            }
        }
    }
    text.to_string()
}

/// 计算字符串与字典中字符的最短距离
///
/// - `from`: 从哪个字符开始匹配
/// - `to`: 匹配到哪个字符（不包含）
/// - `in_order`: 是否从正向开始匹配
///
/// 返回匹配位置的 char 下标
fn seek_index(text: &str, key: &str, from: usize, to: usize, in_order: bool) -> Option<usize> {
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len();
    if len <= from {
        return None;
    }
    let start = if from > 0 { from } else { 0 };
    let end = if to > 0 { to.min(len) } else { len };

    let mut i = start;
    while i < end {
        let c = if in_order {
            chars[i]
        } else {
            chars[len - i - 1]
        };
        if key.contains(c) {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// 计算字符串最后出现与字典中字符匹配的位置
#[allow(dead_code)]
fn seek_last(text: &str, key: &str, from: usize, to: usize) -> Option<usize> {
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len();
    if len <= from {
        return None;
    }
    let mut i = if from < len - 1 { from } else { len - 1 };
    let t = to;
    while i > t {
        if key.contains(chars[i]) {
            return Some(i);
        }
        if i == 0 {
            break;
        }
        i -= 1;
    }
    None
}

/// 计算匹配到字典的每个字符的位置列表
#[allow(dead_code)]
fn seek_indexes(text: &str, key: &str, from: usize, to: usize, in_order: bool) -> Vec<usize> {
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len();
    let mut list: Vec<usize> = Vec::new();
    if len <= from {
        return list;
    }
    let start = if from > 0 { from } else { 0 };
    let end = if to > 0 { to.min(len) } else { len };

    let mut i = start;
    while i < end {
        let c = if in_order {
            chars[i]
        } else {
            chars[len - i - 1]
        };
        if key.contains(c) {
            if let Some(last) = list.last() {
                if i - last == 1 {
                    let last_idx = list.len() - 1;
                    list[last_idx] = i;
                } else {
                    list.push(i);
                }
            } else {
                list.push(i);
            }
        }
        i += 1;
    }
    list
}

/// 对话模式检测与强制切分
///
/// 移植自 Kotlin reduceLength：
/// - 如果连续2对引号的段落没有提示语，进入对话模式
/// - 最后一对引号后强制切分段落
pub fn reduce_dialogue(paragraphs: &[String]) -> Vec<String> {
    let len = paragraphs.len();
    let is_dialogue: Vec<bool> = paragraphs
        .iter()
        .map(|p| is_dialogue_paragraph(p))
        .collect();

    let mut result = paragraphs.to_vec();
    let mut dialogue: i32 = 0;

    for i in 0..len {
        if is_dialogue[i] {
            if dialogue < 0 {
                dialogue = 1;
            } else if dialogue < 2 {
                dialogue += 1;
            }
        } else {
            if dialogue > 1 {
                result[i] = split_quote(&result[i]);
                dialogue -= 1;
            } else if dialogue > 0 && i < len.saturating_sub(2) && is_dialogue[i + 1] {
                result[i] = split_quote(&result[i]);
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty_content() {
        assert_eq!(re_segment("", "第一章"), "");
    }

    #[test]
    fn test_single_paragraph() {
        let content = "这是一段完整的文字内容，没有任何需要分割的地方。";
        let result = re_segment(content, "第一章");
        assert!(!result.is_empty());
        assert!(result.contains("这是一段完整的文字内容"));
    }

    #[test]
    fn test_multiple_paragraphs() {
        let content = "第一段内容结束了。\n\n第二段内容开始了。\n\n第三段内容也结束了。";
        let result = re_segment(content, "第一章");
        assert!(result.contains("第一段内容结束了。"));
        assert!(result.contains("第二段内容开始了。"));
    }

    #[test]
    fn test_dialogue_mode_quotes() {
        let content = "\u{201C}你好，世界！\u{201D}\n\n\u{201C}再见，世界！\u{201D}";
        let result = re_segment(content, "第一章");
        assert!(result.contains("\u{201C}你好，世界！\u{201D}"));
        assert!(result.contains("\u{201C}再见，世界！\u{201D}"));
    }

    #[test]
    fn test_short_paragraph_merge() {
        let paragraphs = vec![
            "这是一段比较长的文字内容。".to_string(),
            "短".to_string(),
            "另一段比较长的文字内容。".to_string(),
        ];
        let result = merge_short_paragraphs(paragraphs);
        // "短" 应该被合并到前一段
        assert_eq!(result.len(), 2);
        assert!(result[0].contains("短"));
    }

    #[test]
    fn test_long_paragraph_split() {
        // 构造一个超过500字符的段落
        let long_text: String = "这是一段很长的文字。".repeat(60);
        let paragraphs = vec![long_text];
        let result = split_long_paragraphs(paragraphs);
        assert!(result.len() > 1);
    }

    #[test]
    fn test_quote_balance() {
        let paragraphs = vec!["\u{201C}未关闭的引号".to_string()];
        let result = balance_quotes(paragraphs);
        assert!(result[0].ends_with('\u{201D}'));
    }

    #[test]
    fn test_quote_balance_already_balanced() {
        let paragraphs = vec!["\u{201C}已平衡的引号\u{201D}".to_string()];
        let result = balance_quotes(paragraphs);
        assert_eq!(result[0], "\u{201C}已平衡的引号\u{201D}");
    }

    #[test]
    fn test_chinese_punctuation() {
        let content = "他说：\u{201C}今天天气真好！\u{201D}然后他就走了。";
        let result = re_segment(content, "第一章");
        assert!(!result.is_empty());
    }

    #[test]
    fn test_reduce_length_basic() {
        let paragraphs: Vec<String> = (0..10).map(|i| format!("段落{}", i)).collect();
        let result = reduce_length(&paragraphs, 5);
        assert!(result.len() <= 5);
    }

    #[test]
    fn test_reduce_length_no_change_needed() {
        let paragraphs = vec!["段落1".to_string(), "段落2".to_string()];
        let result = reduce_length(&paragraphs, 5);
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn test_starts_with_quote() {
        assert!(starts_with_quote("\u{201C}你好"));
        assert!(starts_with_quote("\u{300C}你好"));
        assert!(starts_with_quote("\u{300E}你好"));
        assert!(starts_with_quote("\"你好"));
        assert!(!starts_with_quote("你好"));
    }

    #[test]
    fn test_split_at_sentence() {
        // 每句 27 字符，重复 10 次 = 270 字符，确保超过 100 字符阈值触发分割
        let long_text: String = "这是一个非常长的句子，包含了很多内容，用来测试分割。".repeat(10);
        let result = split_at_sentence(&long_text);
        assert!(
            result.len() > 1,
            "expected > 1 segments, got {}",
            result.len()
        );
        // 每段都应该以句号结尾（最后一段可能追加了剩余内容）
        for (i, segment) in result.iter().enumerate() {
            if i < result.len() - 1 {
                assert!(segment.ends_with('。'));
            }
        }
    }

    #[test]
    fn test_make_dict() {
        let content = "他说\u{201C}你好\u{201D}，她也说\u{201C}你好\u{201D}。";
        let dict = make_dict(content);
        assert!(dict.contains(&"你好".to_string()));
    }

    #[test]
    fn test_make_dict_no_repeat() {
        let content = "他说\u{201C}你好\u{201D}，她说\u{201C}再见\u{201D}。";
        let dict = make_dict(content);
        assert!(dict.is_empty());
    }

    #[test]
    fn test_is_dialogue_paragraph() {
        assert!(is_dialogue_paragraph("\u{201C}这是对话\u{201D}"));
        assert!(!is_dialogue_paragraph("这不是对话"));
        assert!(!is_dialogue_paragraph("\u{201C}未关闭"));
    }

    #[test]
    fn test_split_quote() {
        let text = "\u{201C}你好\u{201D}他说道";
        let result = split_quote(text);
        assert!(result.contains('\n'));
    }

    #[test]
    fn test_split_quote_no_split_needed() {
        let text = "普通文字";
        let result = split_quote(text);
        assert_eq!(result, text);
    }

    #[test]
    fn test_seek_index_forward() {
        let text = "你好。世界。";
        let result = seek_index(text, MARK_SENTENCES_END, 0, 0, true);
        assert_eq!(result, Some(2)); // '。' at index 2
    }

    #[test]
    fn test_seek_index_backward() {
        let text = "你好。世界。";
        let result = seek_index(text, MARK_SENTENCES_END, 0, 0, false);
        // 从后往前找，第一个匹配是最后一个'。'
        assert!(result.is_some());
    }

    #[test]
    fn test_seek_last() {
        let text = "你好。世界。再见";
        let result = seek_last(text, MARK_SENTENCES_END, 5, 0);
        assert_eq!(result, Some(5)); // 第二个'。'
    }

    #[test]
    fn test_seek_indexes() {
        let text = "句一。句二。句三。";
        let result = seek_indexes(text, MARK_SENTENCES_END, 0, 0, true);
        assert_eq!(result.len(), 3);
    }

    #[test]
    fn test_chapter_name_skip() {
        let content = "第一章 开始\n这是正文内容，比较长的段落。";
        let result = re_segment(content, "第一章 开始");
        assert!(!result.contains("第一章 开始"));
        assert!(result.contains("这是正文内容"));
    }

    #[test]
    fn test_reduce_dialogue() {
        let paragraphs = vec![
            "\u{201C}你好\u{201D}".to_string(),
            "\u{201C}再见\u{201D}".to_string(),
            "他说道然后转身离开了这个地方".to_string(),
        ];
        let result = reduce_dialogue(&paragraphs);
        assert_eq!(result.len(), 3);
    }

    #[test]
    fn test_re_segment_with_exclamation() {
        let content = "太好了！我们出发吧。";
        let result = re_segment(content, "");
        assert!(!result.is_empty());
    }

    #[test]
    fn test_is_punctuation() {
        assert!(is_punctuation('。'));
        assert!(is_punctuation('，'));
        assert!(is_punctuation('.'));
        assert!(!is_punctuation('你'));
        assert!(!is_punctuation('a'));
    }
}
