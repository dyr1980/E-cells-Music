// Android 桌面歌词（易格方案）设置页：选项集与交互冒烟测试。
// 旧移动端分支（触摸穿透/隐藏对齐/预览恒左对齐）已随易格方案移除，
// 移动端设置入口整体切换到本页。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/services/android_lyric_service.dart';
import 'package:shiyin_music/ui/pages/android_lyric_settings_page.dart';

class _FakePlayer extends ChangeNotifier implements PlayerController {
  @override
  AndroidLyricSettings androidLyricSettings = const AndroidLyricSettings();

  final List<AndroidLyricSettings> updates = [];

  @override
  Future<void> updateAndroidLyricSettings(AndroidLyricSettings settings) async {
    androidLyricSettings = settings;
    updates.add(settings);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlayer player;

  setUp(() {
    player = _FakePlayer();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: AndroidLyricSettingsPage(player: player)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('渲染易格选项全集：主题模式/双色板/描边/对齐/宽度/时间微调/锁定', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('光感'), findsOneWidget);
    expect(find.text('浅色主题颜色'), findsOneWidget);
    expect(find.text('深色主题颜色'), findsOneWidget);
    expect(find.text('双行歌词'), findsOneWidget);
    expect(find.text('文字描边'), findsOneWidget);
    expect(find.text('对齐方式'), findsOneWidget);
    expect(find.text('悬浮窗宽度'), findsOneWidget);
    expect(find.text('歌词时间微调'), findsOneWidget);
    // 行为区：易格锁定语义（完全穿透 + 背景透明）。
    expect(find.text('锁定歌词'), findsOneWidget);
  });

  testWidgets('点色块切换对应主题色索引；锁定开关回写设置', (tester) async {
    await pumpPage(tester);

    // 浅色板第 5 个色块（索引 4，墨绿）。
    final lightSwatches = find.byKey(
      ValueKey('palette_${Color(AndroidLyricSettings.lightPalette[4]).toARGB32()}'),
    );
    expect(lightSwatches, findsOneWidget);
    await tester.ensureVisible(lightSwatches);
    await tester.pumpAndSettle();
    await tester.tap(lightSwatches);
    await tester.pumpAndSettle();
    expect(player.androidLyricSettings.lightColorIndex, 4);

    // 锁定：完全穿透 + 背景透明的易格语义。行内文字无点击区，点 Switch 本体。
    final lockRow = find.ancestor(
      of: find.text('锁定歌词'),
      matching: find.byType(Row),
    ).first;
    final lockSwitch = find.descendant(
      of: lockRow,
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(lockSwitch);
    await tester.pumpAndSettle();
    await tester.tap(lockSwitch);
    await tester.pumpAndSettle();
    expect(player.androidLyricSettings.locked, isTrue);
    expect(player.updates.last.locked, isTrue);
  });

  testWidgets('恢复默认只还原外观，锁定保持不变', (tester) async {
    player.androidLyricSettings = const AndroidLyricSettings(
      fontSize: 30,
      doubleLine: false,
      locked: true,
      widthPercent: 40,
    );
    await pumpPage(tester);

    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();

    expect(player.androidLyricSettings.fontSize, 18);
    expect(player.androidLyricSettings.doubleLine, isTrue);
    expect(player.androidLyricSettings.widthPercent, 100);
    // 锁定是行为状态：恢复外观不得解锁正在显示的悬浮窗。
    expect(player.androidLyricSettings.locked, isTrue);
  });
}
