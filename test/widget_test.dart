import 'dart:math';

import 'package:connector/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairing codes are compact and shareable', () {
    final code = generatePairingCode(random: Random(7));

    expect(code, hasLength(10));
    expect(RegExp(r'^[A-Z0-9]+$').hasMatch(code), isTrue);
    expect(sanitizePairingCode('ab-c 12'), 'ABC12');
  });
}
