// 歌词对齐方式枚举：pref 解析兜底与各取值的映射关系。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/player/lyric_alignment.dart';

void main() {
  test('fromPref：合法值精确解析，缺失/未知值兜底左对齐', () {
    expect(LyricAlignment.fromPref('left'), LyricAlignment.left);
    expect(LyricAlignment.fromPref('center'), LyricAlignment.center);
    expect(LyricAlignment.fromPref('right'), LyricAlignment.right);
    expect(LyricAlignment.fromPref(null), LyricAlignment.left);
    expect(LyricAlignment.fromPref(''), LyricAlignment.left);
    expect(LyricAlignment.fromPref('bogus'), LyricAlignment.left);
  });

  test('枚举取值携带配套的 Text/Column 对齐映射', () {
    expect(LyricAlignment.left.textAlign, TextAlign.left);
    expect(LyricAlignment.left.crossAxisAlignment, CrossAxisAlignment.start);
    expect(LyricAlignment.center.textAlign, TextAlign.center);
    expect(LyricAlignment.center.crossAxisAlignment, CrossAxisAlignment.center);
    expect(LyricAlignment.right.textAlign, TextAlign.right);
    expect(LyricAlignment.right.crossAxisAlignment, CrossAxisAlignment.end);
    // 三档齐全（弹层按 values 渲染选项）
    expect(LyricAlignment.values.length, 3);
  });
}
