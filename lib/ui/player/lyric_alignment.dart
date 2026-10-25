import 'package:flutter/material.dart';

/// 播放页歌词对齐方式持久化键（移动端歌词页）。
const String kLyricAlignmentPrefKey = 'settings.lyric_alignment';

/// 播放页歌词对齐方式：左对齐 / 居中 / 右对齐。
enum LyricAlignment {
  left('左对齐', TextAlign.left, CrossAxisAlignment.start, 'left'),
  center('居中', TextAlign.center, CrossAxisAlignment.center, 'center'),
  right('右对齐', TextAlign.right, CrossAxisAlignment.end, 'right');

  const LyricAlignment(
    this.label,
    this.textAlign,
    this.crossAxisAlignment,
    this.prefValue,
  );

  /// 中文文案（设置弹层展示）。
  final String label;

  /// 歌词行 [Text] 的对齐（长句换行时对齐方向一致）。
  final TextAlign textAlign;

  /// 歌词行 Column（主行 + 翻译/音译）的交叉轴对齐。
  final CrossAxisAlignment crossAxisAlignment;

  /// SharedPreferences 存储值。
  final String prefValue;

  /// 默认左对齐（与历史版本观感一致）；未知/缺失值兜底为左对齐。
  static LyricAlignment fromPref(String? value) {
    return switch (value) {
      'center' => LyricAlignment.center,
      'right' => LyricAlignment.right,
      _ => LyricAlignment.left,
    };
  }
}
