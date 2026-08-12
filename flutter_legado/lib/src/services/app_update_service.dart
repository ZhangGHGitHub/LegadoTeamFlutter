import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';

/// 检查更新结果（对齐 AppUpdate.UpdateInfo）
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.tagName,
    required this.updateLog,
    required this.downloadUrl,
    required this.fileName,
    this.backupDownloadUrl,
  });

  final String tagName;
  final String updateLog;
  final String downloadUrl;
  final String fileName;
  final String? backupDownloadUrl;
}

class _ReleaseCandidate {
  const _ReleaseCandidate({
    required this.appVariant,
    required this.createdAtMs,
    required this.note,
    required this.name,
    required this.downloadUrl,
    required this.versionName,
  });

  final AppVariant appVariant;
  final int createdAtMs;
  final String note;
  final String name;
  final String downloadUrl;
  final String versionName;
}

enum AppVariant { official, betaRelease, betaReleaseA, unknown }

/// GitHub Release 检查更新（对齐 AppUpdateGitHub + AppUpdateSelector）
///
/// 纯 Flutter HTTP，无新 FFI。
class AppUpdateService {
  AppUpdateService({http.Client? client}) : _client = client ?? http.Client();

  static const releasesUrl =
      'https://api.github.com/repos/LegadoTeam/legado/releases?per_page=30';

  /// 与 pubspec.yaml version 保持同步（无 package_info 时）
  static const currentVersionName = '2.0.38';

  final http.Client _client;

  /// 检查更新；已最新时返回 null；网络/解析失败抛异常。
  ///
  /// [sameMajorOnly] 默认 true：重构版 2.x 只与 2.x Release 比较，
  /// 避免把双轨仓库里的 Android 3.x APK 误报为更新。
  Future<AppUpdateInfo?> check({
    String? currentVersion,
    AppVariant variant = AppVariant.official,
    bool preferArm = true,
    bool sameMajorOnly = true,
  }) async {
    final version = currentVersion ?? currentVersionName;
    final releases = await _fetchReleases();
    final selected = _selectUpdateRelease(
      releases: releases,
      appVariant: variant,
      currentVersionName: version,
      preferArm: preferArm,
      sameMajorOnly: sameMajorOnly,
    );
    if (selected == null) return null;

    final downloadUrl =
        resolveAppUpdateDownloadUrl(selected.name, selected.downloadUrl);
    final backup = resolveAppUpdateBackupUrl(downloadUrl, selected.downloadUrl);
    return AppUpdateInfo(
      tagName: selected.versionName,
      updateLog: selected.note,
      downloadUrl: downloadUrl,
      fileName: selected.name,
      backupDownloadUrl: backup,
    );
  }

  Future<bool> isIgnored(String versionName) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(PrefKeys.ignoreUpdateVersion) == versionName;
  }

  Future<void> setIgnored(String? versionName) async {
    final prefs = await SharedPreferences.getInstance();
    if (versionName == null || versionName.isEmpty) {
      await prefs.remove(PrefKeys.ignoreUpdateVersion);
    } else {
      await prefs.setString(PrefKeys.ignoreUpdateVersion, versionName);
    }
  }

  Future<List<_ReleaseCandidate>> _fetchReleases() async {
    final res = await _client
        .get(
          Uri.parse(releasesUrl),
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'legado-flutter/$currentVersionName',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('获取新版本出错(${res.statusCode})');
    }
    if (res.body.trim().isEmpty) {
      throw StateError('获取新版本出错');
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! List) throw StateError('获取新版本出错');
    final out = <_ReleaseCandidate>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final pre = item['prerelease'] == true;
      if (pre) continue;
      final body = (item['body'] as String?) ?? '';
      final tag = (item['tag_name'] as String?) ?? '';
      final assets = item['assets'];
      if (assets is! List) continue;
      for (final raw in assets) {
        if (raw is! Map<String, dynamic>) continue;
        final contentType = raw['content_type'] as String? ?? '';
        final state = raw['state'] as String? ?? '';
        if (contentType != 'application/vnd.android.package-archive' ||
            state != 'uploaded') {
          continue;
        }
        final name = raw['name'] as String? ?? '';
        final apkUrl = raw['browser_download_url'] as String? ?? '';
        final createdAt = raw['created_at'] as String? ?? '';
        if (name.isEmpty || apkUrl.isEmpty) continue;
        final versionName = parseReleaseVersionName(tag, name);
        if (versionName.isEmpty) continue;
        out.add(
          _ReleaseCandidate(
            appVariant: inferAppVariant(name, pre),
            createdAtMs: DateTime.tryParse(createdAt)?.millisecondsSinceEpoch ??
                0,
            note: body,
            name: name,
            downloadUrl: apkUrl,
            versionName: versionName,
          ),
        );
      }
    }
    out.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return out;
  }
}

/// 对齐 AppUpdateSelector.selectUpdateRelease
_ReleaseCandidate? _selectUpdateRelease({
  required List<_ReleaseCandidate> releases,
  required AppVariant appVariant,
  required String currentVersionName,
  required bool preferArm,
  bool sameMajorOnly = false,
}) {
  final currentMajor = _versionMajor(currentVersionName);
  final candidates = releases.where((r) {
    if (r.appVariant != appVariant) return false;
    if (compareReleaseVersions(r.versionName, currentVersionName) <= 0) {
      return false;
    }
    if (sameMajorOnly && currentMajor != null) {
      final maj = _versionMajor(r.versionName);
      if (maj != currentMajor) return false;
    }
    return true;
  }).toList();
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    final v = compareReleaseVersions(a.versionName, b.versionName);
    if (v != 0) return v;
    return a.createdAtMs.compareTo(b.createdAtMs);
  });
  final latest = candidates.last;
  final sameVersion = candidates
      .where(
        (c) => compareReleaseVersions(c.versionName, latest.versionName) == 0,
      )
      .toList()
    ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
  if (sameVersion.isEmpty) return null;
  if (preferArm) {
    return sameVersion.firstWhere(
      (c) => !isUniversalPackageName(c.name),
      orElse: () => sameVersion.first,
    );
  }
  return sameVersion.firstWhere(
    (c) => isUniversalPackageName(c.name),
    orElse: () => sameVersion.first,
  );
}

int compareReleaseVersions(String left, String right) {
  final leftParts = _toVersionParts(left);
  final rightParts = _toVersionParts(right);
  if (leftParts.isEmpty || rightParts.isEmpty) {
    return left.compareTo(right);
  }
  final n = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var i = 0; i < n; i++) {
    final l = i < leftParts.length ? leftParts[i] : 0;
    final r = i < rightParts.length ? rightParts[i] : 0;
    if (l != r) return l.compareTo(r);
  }
  return 0;
}

List<int> _toVersionParts(String version) {
  final m = RegExp(r'\d+(?:\.\d+)+').firstMatch(version);
  if (m == null) return const [];
  final normalized = normalizeLegadoVersionName(m.group(0)!);
  return normalized
      .split('.')
      .map((p) => int.tryParse(p))
      .whereType<int>()
      .toList();
}

int? _versionMajor(String version) {
  final parts = _toVersionParts(version);
  return parts.isEmpty ? null : parts.first;
}

bool isUniversalPackageName(String fileName) {
  return fileName.contains('通用') ||
      fileName.toLowerCase().contains('universal') ||
      fileName.contains('_._');
}

String resolveAppUpdateDownloadUrl(String fileName, String githubUrl) {
  if (fileName.contains('_._')) return githubUrl;
  return 'https://cdn.mgz.la/app/$fileName';
}

String? resolveAppUpdateBackupUrl(String primaryUrl, String githubUrl) {
  return githubUrl == primaryUrl ? null : githubUrl;
}

AppVariant inferAppVariant(String assetName, bool preRelease) {
  final releaseA = RegExp(
    r'(?:^|[_\-.])releasea(?:[_\-.]|$)',
    caseSensitive: false,
  );
  final release = RegExp(
    r'(?:^|[_\-.])release(?:[_\-.]|$)',
    caseSensitive: false,
  );
  if (releaseA.hasMatch(assetName)) return AppVariant.betaReleaseA;
  if (release.hasMatch(assetName)) return AppVariant.betaRelease;
  if (preRelease) return AppVariant.betaRelease;
  return AppVariant.official;
}

String parseReleaseVersionName(String releaseTag, String assetName) {
  final versionPattern = RegExp(r'\d+(?:\.\d+)+');
  final fromTag = versionPattern.firstMatch(releaseTag)?.group(0);
  final fromAsset = versionPattern.firstMatch(assetName)?.group(0);
  final versionName = fromTag ?? fromAsset;
  if (versionName == null) return '';
  return normalizeLegadoVersionName(versionName);
}

String normalizeLegadoVersionName(String versionName) {
  final versionPattern = RegExp(r'\d+(?:\.\d+)+');
  final version = versionPattern.firstMatch(versionName)?.group(0);
  if (version == null) return versionName;
  final legacy = RegExp(r'^3\.(\d{2})\.(\d{6,})$').firstMatch(version);
  if (legacy != null) {
    final mid = legacy.group(1)!;
    final rest = legacy.group(2)!.substring(0, 6);
    return '3.$mid$rest';
  }
  final compact = RegExp(r'^3\.(\d{8,})$').firstMatch(version);
  if (compact != null) {
    return '3.${compact.group(1)!.substring(0, 8)}';
  }
  return version;
}
