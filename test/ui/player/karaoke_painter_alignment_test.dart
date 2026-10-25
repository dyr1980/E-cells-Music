// 逐字卡拉OK painter 的对齐修复回归：
// 多行排版路径段宽必须撑到 maxWidth（textAlign 才能生效），单行路径
// 保持固有宽；textAlign 变更必须触发重绘。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/player/karaoke_painter.dart';

LyricLine _line(String text) => LyricLine(
      time: Duration.zero,
      duration: const Duration(seconds: 5),
      text: text,
      words: const [
        LyricWord(text: '你', time: Duration.zero, duration: Duration(seconds: 1)),
        LyricWord(
          text: '好',
          time: Duration(seconds: 1),
          duration: Duration(seconds: 1),
        ),
      ],
    );

KaraokeLinePainter _painter({
      required TextAlign textAlign,
      int? maxLines,
      double maxWidth = 400,
    }) =>
    KaraokeLinePainter(
      line: _line('你好'),
      position: Duration.zero,
      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
      baseColor: Colors.white38,
      activeColor: Colors.white,
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
      maxLines: maxLines,
      maxWidth: maxWidth,
    );

void main() {
  test('多行排版路径：段宽撑到 maxWidth，对齐在整行宽度内生效', () {
    final painter = _painter(textAlign: TextAlign.center);
    addTearDown(painter.release);
    // 修复前 minWidth 缺省 0，width 收缩为两字固有宽（远小于 400），
    // paint 恒从最左起画——激活行无视居中设置的根因。
    expect(painter.width, 400);
    expect(painter.height, greaterThan(0));
  });

  test('左对齐与右对齐同样撑满段宽（排版一致，仅内部分配不同）', () {
    final left = _painter(textAlign: TextAlign.left);
    addTearDown(left.release);
    final right = _painter(textAlign: TextAlign.right);
    addTearDown(right.release);
    expect(left.width, 400);
    expect(right.width, 400);
  });

  test('单行路径（maxWidth 为 infinity）：保持固有宽，不触发布局断言', () {
    final painter = _painter(textAlign: TextAlign.center, maxLines: 1);
    addTearDown(painter.release);
    expect(painter.width, lessThan(1000));
    expect(painter.width, greaterThan(0));
  });

  test('shouldRepaint：textAlign 变更必须触发重绘', () {
    final a = _painter(textAlign: TextAlign.left);
    addTearDown(a.release);
    final b = _painter(textAlign: TextAlign.center);
    addTearDown(b.release);
    expect(b.shouldRepaint(a), isTrue, reason: '对齐方式切换需重绘激活行');
  });

  test('shouldRepaint：仅播放位置变化仍触发重绘（原有语义不回归）', () {
    final base = _painter(textAlign: TextAlign.center);
    final moved = base.withPosition(const Duration(seconds: 1));
    addTearDown(moved.release);
    expect(moved.shouldRepaint(base), isTrue);
  });
}
