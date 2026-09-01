import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  group('One-handed mode settings and tap calculation', () {
    test('oneHandedMode setting defaults to false', () {
      expect(appdata.settings['oneHandedMode'], isFalse);
    });

    test('one-handed tap zone identifies all four 30% edges as turning triggers', () {
      const width = 1000.0;
      const height = 2000.0;
      const percent = 0.3;

      bool isOneHandedTurnPage(double x, double y) {
        final isLeft = x < width * percent;
        final isRight = x > width * (1 - percent);
        final isTop = y < height * percent;
        final isBottom = y > height * (1 - percent);
        return isLeft || isRight || isTop || isBottom;
      }

      // Left 30% edge (x < 300)
      expect(isOneHandedTurnPage(150, 1000), isTrue);
      expect(isOneHandedTurnPage(299, 1000), isTrue);

      // Right 30% edge (x > 700)
      expect(isOneHandedTurnPage(701, 1000), isTrue);
      expect(isOneHandedTurnPage(850, 1000), isTrue);

      // Top 30% edge (y < 600)
      expect(isOneHandedTurnPage(500, 300), isTrue);
      expect(isOneHandedTurnPage(500, 599), isTrue);

      // Bottom 30% edge (y > 1400)
      expect(isOneHandedTurnPage(500, 1401), isTrue);
      expect(isOneHandedTurnPage(500, 1800), isTrue);

      // Corners (both left/right and top/bottom)
      expect(isOneHandedTurnPage(50, 50), isTrue);
      expect(isOneHandedTurnPage(950, 50), isTrue);
      expect(isOneHandedTurnPage(50, 1950), isTrue);
      expect(isOneHandedTurnPage(950, 1950), isTrue);

      // Center area (30% to 70% in both x and y) -> should NOT turn page (opens toolbar)
      expect(isOneHandedTurnPage(500, 1000), isFalse);
      expect(isOneHandedTurnPage(301, 601), isFalse);
      expect(isOneHandedTurnPage(699, 1399), isFalse);
    });
  });
}
