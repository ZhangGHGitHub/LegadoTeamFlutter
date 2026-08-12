/// 听书片头/片尾跳过策略（对齐 Rust `audio_skip_policy` / 原版 AudioSkipPolicy）
class AudioSkipWindow {
  const AudioSkipWindow({
    required this.introEndMs,
    required this.outroStartMs,
  });

  final int introEndMs;
  final int outroStartMs;
}

/// 最短剩余可听时长（毫秒）
const int kMinAudioSkipRemainingMs = 5000;

const String kAudioSkipOpenCreditsKey = 'audioSkipOpenCredits';
const String kAudioSkipCloseCreditsKey = 'audioSkipCloseCredits';
const String kAudioPlayWakeLockKey = 'audioPlayWakeLock';
const String kAudioCacheTreeUriKey = 'audioCacheTreeUri';

AudioSkipWindow? resolveAudioSkipWindow({
  required int durationMs,
  required int introSeconds,
  required int outroSeconds,
}) {
  if (durationMs <= 0) return null;
  final introMs = (introSeconds < 0 ? 0 : introSeconds) * 1000;
  final outroMs = (outroSeconds < 0 ? 0 : outroSeconds) * 1000;
  if (durationMs <= introMs + outroMs + kMinAudioSkipRemainingMs) {
    return null;
  }
  return AudioSkipWindow(
    introEndMs: introMs,
    outroStartMs: durationMs - outroMs,
  );
}

int resolveOpenCredits({
  required Map<String, dynamic>? readConfig,
  required int globalOpen,
}) {
  if (readConfig == null) return globalOpen;
  final useGlobal = readConfig['useGlobalAudioSkip'] != false;
  if (useGlobal) return globalOpen;
  final v = readConfig['openCredits'];
  return (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
}

int resolveCloseCredits({
  required Map<String, dynamic>? readConfig,
  required int globalClose,
}) {
  if (readConfig == null) return globalClose;
  final useGlobal = readConfig['useGlobalAudioSkip'] != false;
  if (useGlobal) return globalClose;
  final v = readConfig['closeCredits'];
  return (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
}

int? introSeekPosition({
  required int currentPositionMs,
  required AudioSkipWindow window,
}) {
  if (currentPositionMs > 0) return null;
  if (window.introEndMs <= 0) return null;
  return window.introEndMs;
}

bool shouldSkipOutro({
  required int currentPositionMs,
  required AudioSkipWindow window,
}) {
  return currentPositionMs >= window.outroStartMs;
}
