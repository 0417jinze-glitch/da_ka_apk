import 'dart:convert';

import 'package:da_ka/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('check-in QR contains time, GPS and device code', () {
    final receipt = CheckInReceipt(
      capturedAt: DateTime.utc(2026, 8, 30, 9, 15, 12),
      latitude: 31.230416,
      longitude: 121.473701,
      accuracy: 8.2,
      deviceCode: 'A1B2C3D4E5F60708',
      nonce: 'oneTimeNonce',
    );

    final data = jsonDecode(receipt.qrData) as Map<String, dynamic>;
    expect(data['device'], 'A1B2C3D4E5F60708');
    expect(data['time'], '2026-08-30T09:15:12.000Z');
    expect((data['gps'] as Map<String, dynamic>)['lat'], 31.230416);
    expect(receipt.timestamp, '2026-08-30 09:15:12');
  });
}
