import 'package:desktop_kit/desktop_kit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('package metadata is exported and non-empty', () {
    expect(desktopKitVersion, isNotEmpty);
  });
}
