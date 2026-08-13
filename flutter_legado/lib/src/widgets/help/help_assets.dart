/// 帮助文档资产路径（对标 Android assets/web/help/md/*.md）
abstract final class HelpAssets {
  static const mdDir = 'assets/web/help/md';

  static String mdPath(String fileName) => '$mdDir/$fileName.md';

  static const appHelp = 'appHelp';
  static const sourceMBookHelp = 'SourceMBookHelp';
  static const sourceMRssHelp = 'SourceMRssHelp';
  static const ruleHelp = 'ruleHelp';
  static const rssRuleHelp = 'rssRuleHelp';
  static const jsHelp = 'jsHelp';
  static const regexHelp = 'regexHelp';
  static const xpathHelp = 'xpathHelp';
  static const replaceRuleHelp = 'replaceRuleHelp';
  static const dictRuleHelp = 'dictRuleHelp';
  static const txtTocRuleHelp = 'txtTocRuleHelp';
  static const autoTaskHelp = 'autoTaskHelp';
  static const readMenuHelp = 'readMenuHelp';
  static const webDavHelp = 'webDavHelp';
  static const webDavBookHelp = 'webDavBookHelp';
  static const debugHelp = 'debugHelp';
  static const httpTtsHelp = 'httpTTSHelp';

  /// 存储权限说明（对标 assets/storageHelp.md，不在 md 子目录）
  static const storageHelp = 'assets/storageHelp.md';
}
