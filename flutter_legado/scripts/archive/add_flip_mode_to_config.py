#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import re

file_path = 'lib/src/screens/reader_config_panel.dart'

# Read the file
print(f'Reading {file_path}...')
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Add flip_mode import after dart:async import
content = content.replace(
    "import 'dart:async';",
    "import 'dart:async';\n\nimport '../models/flip_mode.dart';"
)

# 2. Add flipMode field to ReaderAdvancedConfig class
# Find the line with "bool showChapterName;" and add flipMode after it
content = content.replace(
    "  // 状态栏提示栏\n  bool showBattery;\n  bool showTime;\n  bool showProgress;\n  bool showChapterName;",
    "  // 状态栏提示栏\n  bool showBattery;\n  bool showTime;\n  bool showProgress;\n  bool showChapterName;\n\n  // 翻页模式\n  FlipMode flipMode;"
)

# 3. Add flipMode to constructor
content = content.replace(
    "    this.showBattery = true,\n    this.showTime = true,\n    this.showProgress = true,\n    this.showChapterName = true,\n  });",
    "    this.showBattery = true,\n    this.showTime = true,\n    this.showProgress = true,\n    this.showChapterName = true,\n    this.flipMode = FlipMode.slide,\n  });"
)

# 4. Add flipMode to load() method
content = content.replace(
    "      showBattery: prefs.getBool('${_prefix}show_battery') ?? true,\n      showTime: prefs.getBool('${_prefix}show_time') ?? true,\n      showProgress: prefs.getBool('${_prefix}show_progress') ?? true,\n      showChapterName: prefs.getBool('${_prefix}show_chapter_name') ?? true,\n    );",
    "      showBattery: prefs.getBool('${_prefix}show_battery') ?? true,\n      showTime: prefs.getBool('${_prefix}show_time') ?? true,\n      showProgress: prefs.getBool('${_prefix}show_progress') ?? true,\n      showChapterName: prefs.getBool('${_prefix}show_chapter_name') ?? true,\n      flipMode: FlipMode.fromIndex(prefs.getInt('${_prefix}flip_mode') ?? FlipMode.slide.index),\n    );"
)

# 5. Add flipMode to save() method
content = content.replace(
    "    await prefs.setBool('${_prefix}show_battery', showBattery);\n    await prefs.setBool('${_prefix}show_time', showTime);\n    await prefs.setBool('${_prefix}show_progress', showProgress);\n    await prefs.setBool('${_prefix}show_chapter_name', showChapterName);\n  }",
    "    await prefs.setBool('${_prefix}show_battery', showBattery);\n    await prefs.setBool('${_prefix}show_time', showTime);\n    await prefs.setBool('${_prefix}show_progress', showProgress);\n    await prefs.setBool('${_prefix}show_chapter_name', showChapterName);\n    await prefs.setInt('${_prefix}flip_mode', flipMode.index);\n  }"
)

# 6. Add flipMode to copy() method
content = content.replace(
    "        showBattery: showBattery,\n        showTime: showTime,\n        showProgress: showProgress,\n        showChapterName: showChapterName,\n      );",
    "        showBattery: showBattery,\n        showTime: showTime,\n        showProgress: showProgress,\n        showChapterName: showChapterName,\n        flipMode: flipMode,\n      );"
)

# Write back
print(f'Writing {file_path}...')
with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print('Done! Added flipMode to ReaderAdvancedConfig')
