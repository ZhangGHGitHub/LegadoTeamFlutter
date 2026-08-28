# -*- coding: utf-8 -*-
"""md3_colors.dart 生成器（Batch 0 / P1-5 可复现数据源）

从参考仓库 HapeLee/legado-with-MD3 的 res/values/colors.xml 与
values-night/colors.xml 解析 12 套主题 × 47 个 M3 tonal role（亮/暗配对），
生成 flutter_legado/lib/src/theme/md3_colors.dart。

用途：
  1. 数据来源与版本追溯（生成头注释固化 commit sha）；
  2. 参考仓库更新后可重新生成并经 md3_palette_test.dart 校验。

用法（需先取得参考仓库 colors.xml / colors_night.xml，UI_MD3_PLAN.md 第五节）：
  python tool/gen_md3_colors.py <colors.xml> <colors_night.xml>

注意：本脚本读取参考仓库原始资源，生成物已固化进版本库；
     `.tmp_net/` 研究产物清理后仍可按此脚本说明重新取数再生成。
"""
import re
import sys

# 亮/暗合并后输出顺序（与 Material 3 规范 role 集一致，47 个）
ROLE_ORDER = [
    'primary', 'onPrimary', 'primaryContainer', 'onPrimaryContainer',
    'secondary', 'onSecondary', 'secondaryContainer', 'onSecondaryContainer',
    'tertiary', 'onTertiary', 'tertiaryContainer', 'onTertiaryContainer',
    'error', 'onError', 'errorContainer', 'onErrorContainer',
    'background', 'onBackground',
    'surface', 'onSurface', 'surfaceVariant', 'onSurfaceVariant',
    'outline', 'outlineVariant', 'scrim',
    'inverseSurface', 'inverseOnSurface', 'inversePrimary',
    'primaryFixed', 'onPrimaryFixed', 'primaryFixedDim', 'onPrimaryFixedVariant',
    'secondaryFixed', 'onSecondaryFixed', 'secondaryFixedDim', 'onSecondaryFixedVariant',
    'tertiaryFixed', 'onTertiaryFixed', 'tertiaryFixedDim', 'onTertiaryFixedVariant',
    'surfaceDim', 'surfaceBright',
    'surfaceContainerLowest', 'surfaceContainerLow',
    'surfaceContainer', 'surfaceContainerHigh', 'surfaceContainerHighest',
]

# 调色板清单（id, 中文显示名）；默认主题 WH 置首
PALETTES = [
    ('wh', '纯白'),
    ('gr', '森绿'),
    ('lemon', '柠檬'),
    ('koharu', '小春'),
    ('yuuka', '优香'),
    ('phoebe', '菲比'),
    ('sora', '穹'),
    ('august', '八月'),
    ('carlotta', '卡洛塔'),
    ('mujika', '姆吉卡'),
    ('elink', '墨水'),
    ('transparent', '透明'),
]

SOURCE_COMMIT = '6dc297221a22e532354810fb2804592dd08e5a9d'


def parse_colors(path):
    text = open(path, encoding='utf-8').read()
    return {
        m.group(1): m.group(2)
        for m in re.finditer(r'<color name="([^"]+)">(#[0-9A-Fa-f]+)</color>', text)
    }


def to_argb(hexs):
    h = hexs.lstrip('#')
    if len(h) == 6:
        h = 'FF' + h
    return '0x' + h.upper()


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    light = parse_colors(sys.argv[1])
    night = parse_colors(sys.argv[2])

    lines = []
    w = lines.append
    w('// 由 tool/gen_md3_colors.py 从参考仓库资源生成（Batch 0 / P1-5）')
    w('// 来源：HapeLee/legado-with-MD3@%s' % SOURCE_COMMIT)
    w('//       app/src/main/res/values/colors.xml + values-night/colors.xml')
    w('// 每套 47 个 M3 tonal role（亮/暗配对），role 值逐字拷贝自参考仓库（非重推导）；')
    w('// transparent 主题缺 surfaceContainerLow，按其 surface（全透明）回补。')
    w('// 修改本文件请改走生成器，并同步更新 test/unit/md3_palette_test.dart 锚点。')
    w('')
    w("import 'package:flutter/material.dart';")
    w('')
    w('/// 一套调色板单个亮度下的 47 个 M3 tonal role（ARGB int）')
    w('class Md3Roles {')
    for role in ROLE_ORDER:
        w('  final int %s;' % role)
    w('')
    w('  const Md3Roles({')
    for role in ROLE_ORDER:
        w('    required this.%s,' % role)
    w('  });')
    w('}')
    w('')
    w('/// 一套内置 MD3 调色板：亮/暗 tonal 配对 + 来源锚点')
    w('class Md3Palette {')
    w('  /// 调色板标识（SharedPreferences paletteId 存储值）')
    w('  final String id;')
    w('')
    w('  /// 中文显示名（主题选择器用）')
    w('  final String label;')
    w('')
    w('  /// seed 锚点：参考仓库该主题亮色 colorPrimary（用于溯源，非重推导种子）')
    w('  final int seed;')
    w('')
    w('  final Md3Roles light;')
    w('  final Md3Roles dark;')
    w('')
    w('  const Md3Palette({')
    w('    required this.id,')
    w('    required this.label,')
    w('    required this.seed,')
    w('    required this.light,')
    w('    required this.dark,')
    w('  });')
    w('}')
    w('')
    w('/// 12 套内置 MD3 调色板（UI_MD3_PLAN.md 第三节：默认 WH）')
    w('abstract final class Md3Palettes {')
    for pid, label in PALETTES:
        pre = pid + '_theme_'
        seed = to_argb(light[pre + 'primary'])
        w('  static const %s = Md3Palette(' % pid)
        w("    id: '%s'," % pid)
        w("    label: '%s'," % label)
        w('    seed: %s,' % seed)
        for mode, src in (('light', light), ('dark', night)):
            w('    %s: Md3Roles(' % mode)
            for role in ROLE_ORDER:
                key = pre + role
                if key in src:
                    value = to_argb(src[key])
                elif pid == 'transparent' and role == 'surfaceContainerLow':
                    value = to_argb(src[pre + 'surface'])
                    w('      // transparent 原资源缺此项，按 surface 回补')
                else:
                    raise SystemExit('缺失 role: %s' % key)
                w('      %s: %s,' % (role, value))
            w('    ),')
        w('  );')
        w('')
    w('  /// 默认调色板（UI_MD3_PLAN.md 第十六节：WH）')
    w("  static const String defaultId = 'wh';")
    w('')
    w('  /// 全部内置调色板（顺序即主题选择器展示顺序）')
    w('  static const List<Md3Palette> all = [')
    for pid, _ in PALETTES:
        w('    %s,' % pid)
    w('  ];')
    w('')
    w('  /// 按 id 取调色板；未知 id 回退默认 WH（回滚路径，UI_MD3_PLAN.md 第九节）')
    w('  static Md3Palette byId(String id) =>')
    w("      all.firstWhere((p) => p.id == id, orElse: () => wh);")
    w('}')
    w('')
    w('/// ColorScheme 构建：跳过 background/onBackground/surfaceVariant 三个')
    w('/// 已废弃参数（数据保留在 [Md3Roles] 供校验，scheme 由 surface 系派生）。')
    w('ColorScheme md3LightScheme(Md3Palette p) => ColorScheme(')
    w('  brightness: Brightness.light,')
    _emit_scheme(lines, 'p.light.')
    w(');')
    w('')
    w('/// 暗色 ColorScheme（着色暗面，非纯黑；UI_MD3_PLAN.md 第三节）')
    w('ColorScheme md3DarkScheme(Md3Palette p) => ColorScheme(')
    w('  brightness: Brightness.dark,')
    _emit_scheme(lines, 'p.dark.')
    w(');')

    out = '\n'.join(lines) + '\n'
    target = 'lib/src/theme/md3_colors.dart'
    with open(target, 'w', encoding='utf-8', newline='\n') as f:
        f.write(out)
    print('生成完成:', target, '(%d 行)' % (out.count('\n') + 1))


def _emit_scheme(lines, prefix):
    w = lines.append
    # XML role 名 → ColorScheme 参数名（inverseOnSurface → onInverseSurface）
    param_names = {'inverseOnSurface': 'onInverseSurface'}
    scheme_roles = [r for r in ROLE_ORDER
                    if r not in ('background', 'onBackground', 'surfaceVariant')]
    for role in scheme_roles:
        param = param_names.get(role, role)
        w('  %s%s: Color(%s%s),' % (param, ' ' * (24 - len(param)), prefix, role))


if __name__ == '__main__':
    main()
