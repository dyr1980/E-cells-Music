// AndroidLyricSettings 序列化与光感值兼容性测试。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/android_lyric_service.dart';

void main() {
  test('toMap/fromMap 往返保留光感值', () {
    const settings = AndroidLyricSettings(sensorDarkThreshold: 320);
    final restored = AndroidLyricSettings.fromMap(settings.toMap());
    expect(restored, settings);
    expect(restored.sensorDarkThreshold, 320);
  });

  test('旧版本 JSON 无 sensorDarkThreshold 键：回落默认 15', () {
    final restored = AndroidLyricSettings.fromMap({
      'lightColorIndex': 2,
      'darkColorIndex': 3,
      'themeMode': AndroidLyricThemeMode.sensor,
      'fontSize': 22.0,
      'doubleLine': false,
      'locked': true,
      'widthPercent': 60,
      'strokeEnabled': true,
      'alignment': 'left',
      'lyricOffsetMs': 500,
    });
    expect(
      restored.sensorDarkThreshold,
      AndroidLyricSettings.defaultSensorDarkThreshold,
    );
  });

  test('越界光感值被钳制到合法区间', () {
    expect(
      AndroidLyricSettings.fromMap(const {'sensorDarkThreshold': 1})
          .sensorDarkThreshold,
      AndroidLyricSettings.sensorDarkThresholdMin,
    );
    expect(
      AndroidLyricSettings.fromMap(const {'sensorDarkThreshold': 99999})
          .sensorDarkThreshold,
      AndroidLyricSettings.sensorDarkThresholdMax,
    );
  });

  test('恢复默认外观时光感值回到 15', () {
    const settings = AndroidLyricSettings(
      themeMode: AndroidLyricThemeMode.sensor,
      sensorDarkThreshold: 400,
    );
    expect(
      settings.withDefaultAppearance().sensorDarkThreshold,
      AndroidLyricSettings.defaultSensorDarkThreshold,
    );
  });
}
