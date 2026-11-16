// 阅读统计（热力图 / 按天视图）的私密脱敏判定
//
// 背景：`readRecordDaily`（热力图与按天视图的每日时长数据源）只有
// `date + durationSeconds` 两列，**没有书籍维度**，因此无法在 Dart 侧
// 从某天的聚合值里剔除「私密书贡献的那部分秒数」。
//
// 处置（fail-closed，宁可少展示也不泄漏）：
// - 快照/策略未就绪（首帧竞态）：统计区显示中性占位，绝不先渲染真实
//   时长——与首页最近阅读的 pending 态同口径；
// - 存在「私密且未获准」的阅读记录时：每日时长不可信（聚合值包含私密
//   书时长），故隐藏时长序列；「按本数」模式的数据源是逐条记录，可以
//   真正按书剔除（见 [filterLockedRecords]）。
//
// 与「阅读记录页脱敏」同一判定（`PrivacyContentSnapshot.isRecordLocked`，
// 物理名优先、显示名兜底），避免两处口径漂移。
//
// 编写：全栈工程师（A3 热力图脱敏） ｜ 2026-11-17
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../providers/privacy/privacy_state.dart';
import '../services/privacy_content_service.dart';

/// 隐私快照是否已足以做出脱敏判定（未就绪时统计区只能显示占位）
///
/// - 策略未加载：无法判断是否启用/是否验证，必须先占位；
/// - 总开关关闭：私密判定恒不成立，无需等标记快照；
/// - 已启用但标记未加载：空快照会把私密书判成非私密（fail-open），必须占位。
bool readStatsPrivacyReady(
  PrivacyState privacy,
  PrivacyContentSnapshot content,
) {
  if (!privacy.loaded) return false;
  // 总开关关闭 / 关闭「打开书籍时验证」：私密判定恒不成立，无需等标记
  //（与 PrivateBookGate 的放行口径一致，避免非私密用户首帧多等一次 IO）。
  if (!privacy.enabled || !privacy.verifyOnOpenBook) return true;
  return content.loaded;
}

/// 记录是否因「私密且未获准」而必须从统计中剔除
///
/// 记录的展示名可能被用户改过，物理名才是落库键；两把键都查，
/// 避免任一形态漏判（与阅读记录列表 `_recordKeyOf` 同口径）。
bool isRecordHiddenFromStats(
  ReadRecordShow record,
  PrivacyState privacy,
  PrivacyContentSnapshot content,
) {
  if (!privacy.loaded || !privacy.enabled || !privacy.verifyOnOpenBook) {
    return false;
  }
  if (!content.loaded) return false; // 未就绪由 [readStatsPrivacyReady] 处理
  final physical = record.physicalBookName.isNotEmpty
      ? record.physicalBookName
      : record.bookName;
  final keys = <PrivacyRecordKey>[
    PrivacyRecordKey(physical, record.author),
    if (record.bookName != physical)
      PrivacyRecordKey(record.bookName, record.author),
  ];
  return keys.any((key) => content.isRecordLocked(key, privacy));
}

/// 从统计口径剔除私密未授权记录（「按本数」热力图数据源）
List<ReadRecordShow> filterLockedRecords(
  List<ReadRecordShow> records,
  PrivacyState privacy,
  PrivacyContentSnapshot content,
) {
  if (!privacy.loaded || !privacy.enabled || !privacy.verifyOnOpenBook) {
    return records;
  }
  if (!content.loaded) return records;
  return [
    for (final r in records)
      if (!isRecordHiddenFromStats(r, privacy, content)) r,
  ];
}

/// 是否存在任何「私密且未获准」的记录（存在则每日时长聚合不可信）
bool hasLockedRecordsForStats(
  List<ReadRecordShow> records,
  PrivacyState privacy,
  PrivacyContentSnapshot content,
) {
  if (!privacy.loaded || !privacy.enabled || !privacy.verifyOnOpenBook) {
    return false;
  }
  if (!content.loaded) return false;
  for (final r in records) {
    if (isRecordHiddenFromStats(r, privacy, content)) return true;
  }
  return false;
}

/// 记录键（与阅读记录页一致；测试与调用方复用）
@visibleForTesting
PrivacyRecordKey recordKeyOf(ReadRecordShow record) => PrivacyRecordKey(
  record.physicalBookName.isNotEmpty
      ? record.physicalBookName
      : record.bookName,
  record.author,
);
