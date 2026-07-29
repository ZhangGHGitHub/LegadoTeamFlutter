/// 中文断行排版引擎
///
/// 移植自 Kotlin ZhLayout.kt (278行) — 作者 hoodie13
/// 针对中文的断行排版处理，因为 Flutter 默认断行对标点处理不符合国人习惯。
///
/// 核心算法：逐字累加宽度 → 超宽时判断断行模式（6种）→ 处理标点避头尾
library;

/// 断行模式
///
/// 对应 Kotlin ZhLayout.BreakMod
enum BreakMod {
  /// 模式0：正常断行
  normal,

  /// 模式1：当前行下移一个字
  breakOneChar,

  /// 模式2：当前行下移多个字
  breakMoreChar,

  /// 模式3：两个后置标点压缩
  cps1,

  /// 模式4：前置标点压缩+前置标点压缩+字
  cps2,

  /// 模式5：前置标点压缩+字+后置标点压缩
  cps3,
}

/// 中文断行排版结果
///
/// 移植自 Kotlin ZhLayout.kt
/// 输入逐字宽度列表，输出断行位置与每行宽度
class ZhLayout {
  /// 不能出现在行首的标点（后置标点）
  ///
  /// 对应 Kotlin postPanc — 这些标点应跟随前一个字，不能单独出现在下一行行首
  static const Set<String> postPanc = {
    '，', '。', '：', '？', '！', '、', '\u201d', '\u2019', '）', '》', '}',
    '】', ')', '>', ']', ',', '.', '?', '!', ':', '」', '；', ';',
  };

  /// 不能出现在行末的标点（前置标点）
  ///
  /// 对应 Kotlin prePanc — 这些标点应跟随后一个字，不能单独留在上一行行末
  static const Set<String> prePanc = {
    '\u201c', '（', '《', '【', '\u2018', '(', '<', '[', '{', '「',
  };

  /// 每行的起始字符索引
  ///
  /// 对应 Kotlin lineStart: IntArray
  final List<int> lineStart;

  /// 每行的实际宽度
  ///
  /// 对应 Kotlin lineWidth: FloatArray
  final List<double> lineWidth;

  /// 总行数
  final int lineCount;

  /// 内部构造函数（通过 [ZhLayout.compute] 创建）
  ZhLayout._(this.lineStart, this.lineWidth, this.lineCount);

  /// 计算断行（推荐入口）
  ///
  /// 忠实移植 Kotlin ZhLayout init 块中的断行算法
  static ZhLayout compute({
    required List<String> words,
    required List<double> widths,
    required double availableWidth,
    int indentSize = 0,
    double cnCharWidth = 18.0,
  }) {
    const defaultCapacity = 10;
    var lineStartArr = List<int>.filled(defaultCapacity, 0);
    var lineWidthArr = List<double>.filled(defaultCapacity, 0.0);

    var line = 0;
    var lineW = 0.0;
    var cwPre = 0.0;
    var length = 0;

    for (var index = 0; index < words.length; index++) {
      final s = words[index];
      final cw = widths[index];
      var breakMod = BreakMod.normal;
      var breakLine = false;
      lineW += cw;
      var offset = 0.0;
      var breakCharCnt = 0;

      if (lineW > availableWidth) {
        /* 禁止在行尾的标点处理 */
        if (index >= 1 && _isPrePanc(words[index - 1])) {
          if (index >= 2 && _isPrePanc(words[index - 2])) {
            breakMod = BreakMod.cps2; // 如果前面还有一个禁末标点则异常
          } else {
            breakMod = BreakMod.breakOneChar; // 无异常场景
          }
        }
        /* 禁止在行首的标点处理 */
        else if (_isPostPanc(words[index])) {
          if (index >= 1 && _isPostPanc(words[index - 1])) {
            breakMod = BreakMod.cps1; // 如果前面还有一个禁首标点则异常
          } else if (index >= 2 && _isPrePanc(words[index - 2])) {
            breakMod = BreakMod.cps3; // 如果前面还有一个禁末标点则异常
          } else {
            breakMod = BreakMod.breakOneChar; // 无异常场景
          }
        } else {
          breakMod = BreakMod.normal; // 无异常场景
        }

        /* 判断上述逻辑解决不了的特殊情况 */
        var reCheck = false;
        var breakIndex = 0;
        if (breakMod == BreakMod.cps1 &&
            (_inCompressible(widths[index], cnCharWidth) ||
                _inCompressible(widths[index - 1], cnCharWidth))) {
          reCheck = true;
        }
        if (breakMod == BreakMod.cps2 &&
            (_inCompressible(widths[index - 1], cnCharWidth) ||
                _inCompressible(widths[index - 2], cnCharWidth))) {
          reCheck = true;
        }
        if (breakMod == BreakMod.cps3 &&
            (_inCompressible(widths[index], cnCharWidth) ||
                _inCompressible(widths[index - 2], cnCharWidth))) {
          reCheck = true;
        }
        if (_breakModOrdinal(breakMod) > _breakModOrdinal(BreakMod.breakMoreChar) &&
            index < words.length - 1 &&
            _isPostPanc(words[index + 1])) {
          reCheck = true;
        }

        /* 特殊标点使用难保证显示效果，所以不考虑间隔，直接查找到能满足条件的分割字 */
        var breakLength = 0;
        if (reCheck && index > 2) {
          final startPos = line == 0 ? indentSize : lineStartArr[line];
          breakMod = BreakMod.normal;
          for (var i = index; i >= 1 + startPos; i--) {
            if (i == index) {
              breakIndex = 0;
              cwPre = 0.0;
            } else {
              breakIndex++;
              breakLength += words[i].length;
              cwPre += widths[i];
            }
            if (!_isPostPanc(words[i]) && !_isPrePanc(words[i - 1])) {
              breakMod = BreakMod.breakMoreChar;
              break;
            }
          }
        }

        switch (breakMod) {
          case BreakMod.normal:
            // 模式0：正常断行
            offset = cw;
            if (line + 1 >= lineStartArr.length) {
              final newLen = line + 1 + defaultCapacity;
              lineStartArr = _growIntList(lineStartArr, newLen);
              lineWidthArr = _growDoubleList(lineWidthArr, newLen);
            }
            lineStartArr[line + 1] = length;
            breakCharCnt = 1;

          case BreakMod.breakOneChar:
            // 模式1：当前行下移一个字
            offset = cw + cwPre;
            if (line + 1 >= lineStartArr.length) {
              final newLen = line + 1 + defaultCapacity;
              lineStartArr = _growIntList(lineStartArr, newLen);
              lineWidthArr = _growDoubleList(lineWidthArr, newLen);
            }
            lineStartArr[line + 1] = length - words[index - 1].length;
            breakCharCnt = 2;

          case BreakMod.breakMoreChar:
            // 模式2：当前行下移多个字
            offset = cw + cwPre;
            if (line + 1 >= lineStartArr.length) {
              final newLen = line + 1 + defaultCapacity;
              lineStartArr = _growIntList(lineStartArr, newLen);
              lineWidthArr = _growDoubleList(lineWidthArr, newLen);
            }
            lineStartArr[line + 1] = length - breakLength;
            breakCharCnt = breakIndex + 1;

          case BreakMod.cps1:
            // 模式3：两个后置标点压缩
            offset = 0.0;
            if (line + 1 >= lineStartArr.length) {
              final newLen = line + 1 + defaultCapacity;
              lineStartArr = _growIntList(lineStartArr, newLen);
              lineWidthArr = _growDoubleList(lineWidthArr, newLen);
            }
            lineStartArr[line + 1] = length + s.length;
            breakCharCnt = 0;

          case BreakMod.cps2:
            // 模式4：前置标点压缩+前置标点压缩+字
            offset = 0.0;
            if (line + 1 >= lineStartArr.length) {
              final newLen = line + 1 + defaultCapacity;
              lineStartArr = _growIntList(lineStartArr, newLen);
              lineWidthArr = _growDoubleList(lineWidthArr, newLen);
            }
            lineStartArr[line + 1] = length + s.length;
            breakCharCnt = 0;

          case BreakMod.cps3:
            // 模式5：前置标点压缩+字+后置标点压缩
            offset = 0.0;
            if (line + 1 >= lineStartArr.length) {
              final newLen = line + 1 + defaultCapacity;
              lineStartArr = _growIntList(lineStartArr, newLen);
              lineWidthArr = _growDoubleList(lineWidthArr, newLen);
            }
            lineStartArr[line + 1] = length + s.length;
            breakCharCnt = 0;
        }
        breakLine = true;
      }

      /* 当前行写满情况下的断行 */
      if (breakLine) {
        lineWidthArr[line] = lineW - offset;
        lineW = offset;
        line++;
        if (line + 1 >= lineStartArr.length) {
          final newLen = line + 1 + defaultCapacity;
          lineStartArr = _growIntList(lineStartArr, newLen);
          lineWidthArr = _growDoubleList(lineWidthArr, newLen);
        }
      }

      /* 已到最后一个字符 */
      if (words.length - 1 == index) {
        if (!breakLine) {
          offset = 0.0;
          if (line + 1 >= lineStartArr.length) {
            final newLen = line + 1 + defaultCapacity;
            lineStartArr = _growIntList(lineStartArr, newLen);
            lineWidthArr = _growDoubleList(lineWidthArr, newLen);
          }
          lineStartArr[line + 1] = length + s.length;
          lineWidthArr[line] = lineW - offset;
          lineW = offset;
          line++;
        }
        /* 写满断行、段落末尾、且需要下移字符，这种特殊情况下要额外多一行 */
        else if (breakCharCnt > 0) {
          if (line + 1 >= lineStartArr.length) {
            final newLen = line + 1 + defaultCapacity;
            lineStartArr = _growIntList(lineStartArr, newLen);
            lineWidthArr = _growDoubleList(lineWidthArr, newLen);
          }
          lineStartArr[line + 1] = lineStartArr[line] + breakCharCnt;
          lineWidthArr[line] = lineW;
          line++;
        }
      }
      length += s.length;
      cwPre = cw;
    }

    return ZhLayout._(
      lineStartArr.sublist(0, line + 1),
      lineWidthArr.sublist(0, line),
      line,
    );
  }

  /// 获取指定行的起始字符索引
  int getLineStart(int line) => lineStart[line];

  /// 获取指定行的结束字符索引
  int getLineEnd(int line) {
    if (line + 1 < lineStart.length) {
      return lineStart[line + 1];
    }
    return lineStart[line]; // fallback
  }

  /// 获取指定行的宽度
  double getLineWidth(int line) => lineWidth[line];

  // --- 私有辅助方法 ---

  static bool _isPostPanc(String s) => postPanc.contains(s);

  static bool _isPrePanc(String s) => prePanc.contains(s);

  /// 判断标点是否可压缩（宽度小于中文字符宽度）
  static bool _inCompressible(double width, double cnCharWidth) {
    return width < cnCharWidth;
  }

  /// BreakMod 序号比较（对应 Kotlin enum ordinal）
  static int _breakModOrdinal(BreakMod mod) => mod.index;

  static List<int> _growIntList(List<int> list, int newLength) {
    final newList = List<int>.filled(newLength, 0);
    for (var i = 0; i < list.length && i < newLength; i++) {
      newList[i] = list[i];
    }
    return newList;
  }

  static List<double> _growDoubleList(List<double> list, int newLength) {
    final newList = List<double>.filled(newLength, 0.0);
    for (var i = 0; i < list.length && i < newLength; i++) {
      newList[i] = list[i];
    }
    return newList;
  }
}

/// 文本测量工具
///
/// 移植自 TextChapterLayout.kt 的 measureTextSplit
/// 将文本拆分为逐字列表 + 对应宽度列表
class TextMeasure {
  /// 将文本拆分为字符列表（处理组合字符）
  ///
  /// 对应 Kotlin measureTextSplit：
  /// 宽度为0的后续字符合并到前一个字符（组合字符/零宽字符）
  static (List<String>, List<double>) splitByWidths(
    String text,
    List<double> widthsArray, [
    int start = 0,
  ]) {
    final length = text.length;
    final words = <String>[];
    final widths = <double>[];

    var i = 0;
    while (i < length) {
      final clusterBaseIndex = i;
      i++;
      widths.add(widthsArray[start + clusterBaseIndex]);
      // 合并零宽字符到当前 cluster
      while (i < length &&
          widthsArray[start + i] == 0.0 &&
          !_isZeroWidthChar(text[i])) {
        i++;
      }
      words.add(text.substring(clusterBaseIndex, i));
    }

    return (words, widths);
  }

  /// 判断是否为零宽字符
  static bool _isZeroWidthChar(String char) {
    final code = char.codeUnitAt(0);
    // 零宽空格、零宽连接符、零宽非连接符、BOM 等
    return code == 0x200B ||
        code == 0x200C ||
        code == 0x200D ||
        code == 0xFEFF ||
        code == 0x00AD;
  }
}
