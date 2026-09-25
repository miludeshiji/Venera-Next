import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The default in Settings._data is 'system'.
  const defaultLanguage = 'system';

  setUp(() {
    appdata.settings['language'] = defaultLanguage;
  });

  tearDown(() {
    appdata.settings['language'] = defaultLanguage;
  });

  group('App.locale explicit language setting', () {
    test('zh-CN selects simplified Chinese', () {
      appdata.settings['language'] = 'zh-CN';
      expect(App.locale, const Locale('zh', 'CN'));
    });

    test('zh-TW selects traditional Chinese', () {
      appdata.settings['language'] = 'zh-TW';
      expect(App.locale, const Locale('zh', 'TW'));
    });

    test('en-US selects English as en_US', () {
      appdata.settings['language'] = 'en-US';
      expect(App.locale, const Locale('en', 'US'));
    });

    test('explicit choice overrides the reported system locale', () {
      // The tester reports English first, so an unrelated bug could leak the
      // system value through; the explicit setting must win.
      appdata.settings['language'] = 'zh-TW';
      expect(App.locale, const Locale('zh', 'TW'));
      appdata.settings['language'] = 'zh-CN';
      expect(App.locale, const Locale('zh', 'CN'));
    });
  });

  group('App.locale system language under flutter_tester', () {
    test(
      'system resolves to the first supported reported language as en_US',
      () {
        appdata.settings['language'] = 'system';
        expect(App.locale, const Locale('en', 'US'));
      },
    );

    test('unrecognized setting value falls back to system resolution', () {
      appdata.settings['language'] = 'fr-FR';
      expect(App.locale, const Locale('en', 'US'));
    });

    test(
      'restoring system resumes system resolution after an explicit choice',
      () {
        appdata.settings['language'] = 'zh-TW';
        expect(App.locale, const Locale('zh', 'TW'));

        appdata.settings['language'] = 'system';
        expect(App.locale, const Locale('en', 'US'));
      },
    );
  });

  group('production locale resolution', () {
    final cases = <({String name, List<Locale> system, Locale expected})>[
      (
        name: 'zh-Hans-US: script beats region',
        system: [
          const Locale.fromSubtags(
            languageCode: 'zh',
            countryCode: 'US',
            scriptCode: 'Hans',
          ),
        ],
        expected: const Locale('zh', 'CN'),
      ),
      (
        name: 'zh-Hans-CN: simplified',
        system: [
          const Locale.fromSubtags(
            languageCode: 'zh',
            countryCode: 'CN',
            scriptCode: 'Hans',
          ),
        ],
        expected: const Locale('zh', 'CN'),
      ),
      (
        name: 'zh-Hant: script only',
        system: [
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        ],
        expected: const Locale('zh', 'TW'),
      ),
      (
        name: 'zh-Hant-CN: script beats region',
        system: [
          const Locale.fromSubtags(
            languageCode: 'zh',
            countryCode: 'CN',
            scriptCode: 'Hant',
          ),
        ],
        expected: const Locale('zh', 'TW'),
      ),
      (
        name: 'zh-TW: traditional region fallback',
        system: [const Locale('zh', 'TW')],
        expected: const Locale('zh', 'TW'),
      ),
      (
        name: 'zh-HK: traditional region fallback',
        system: [const Locale('zh', 'HK')],
        expected: const Locale('zh', 'TW'),
      ),
      (
        name: 'zh-MO: traditional region fallback',
        system: [const Locale('zh', 'MO')],
        expected: const Locale('zh', 'TW'),
      ),
      (
        name: 'zh-CN: simplified region',
        system: [const Locale('zh', 'CN')],
        expected: const Locale('zh', 'CN'),
      ),
      (
        name: 'zh-SG: simplified region',
        system: [const Locale('zh', 'SG')],
        expected: const Locale('zh', 'CN'),
      ),
      (
        name: 'zh without region: simplified',
        system: [const Locale('zh')],
        expected: const Locale('zh', 'CN'),
      ),
      (
        name: 'en-GB: English retains US region for comic source compatibility',
        system: [const Locale('en', 'GB')],
        expected: const Locale('en', 'US'),
      ),
      (
        name: 'en-US: English retains US region',
        system: [const Locale('en', 'US')],
        expected: const Locale('en', 'US'),
      ),
      (
        name: 'non zh/en language falls back to English en_US',
        system: [const Locale('fr', 'FR')],
        expected: const Locale('en', 'US'),
      ),
      (
        name: 'empty reported list falls back to English en_US',
        system: <Locale>[],
        expected: const Locale('en', 'US'),
      ),
      (
        name: 'first matching language wins: English before Chinese',
        system: [const Locale('en', 'US'), const Locale('zh', 'CN')],
        expected: const Locale('en', 'US'),
      ),
      (
        name: 'first matching language wins: Chinese before English',
        system: [const Locale('zh', 'HK'), const Locale('en', 'US')],
        expected: const Locale('zh', 'TW'),
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        expect(resolveAppLocale('system', testCase.system), testCase.expected);
      });
    }

    test('App.locale delegates to the production resolver', () {
      appdata.settings['language'] = 'system';
      expect(
        resolveAppLocale('system', PlatformDispatcher.instance.locales),
        App.locale,
      );
    });
  });

  group('JS script locale compatibility', () {
    test('English locale never produces en_null in getLocale', () {
      appdata.settings['language'] = 'en-US';
      final localeStr = '${App.locale.languageCode}_${App.locale.countryCode}';
      expect(localeStr, 'en_US');
      expect(localeStr, isNot(contains('null')));
    });

    test('system English fallback never produces en_null in getLocale', () {
      appdata.settings['language'] = 'system';
      final locale = resolveAppLocale('system', [const Locale('en')]);
      final localeStr = '${locale.languageCode}_${locale.countryCode}';
      expect(localeStr, 'en_US');
      expect(localeStr, isNot(contains('null')));
    });

    test('all supported regions have non-null countryCode', () {
      final regions = <({String pref, String expected})>[
        (pref: 'zh-CN', expected: 'zh_CN'),
        (pref: 'zh-TW', expected: 'zh_TW'),
        (pref: 'en-US', expected: 'en_US'),
      ];
      for (final r in regions) {
        appdata.settings['language'] = r.pref;
        final key = '${App.locale.languageCode}_${App.locale.countryCode}';
        expect(key, r.expected);
        expect(App.locale.countryCode, isNotNull);
      }
    });

    test('all Chinese region fallbacks have non-null countryCode', () {
      final testCases = <({Locale system, String expected})>[
        (system: const Locale('zh', 'CN'), expected: 'zh_CN'),
        (system: const Locale('zh', 'SG'), expected: 'zh_CN'),
        (system: const Locale('zh', 'TW'), expected: 'zh_TW'),
        (system: const Locale('zh', 'HK'), expected: 'zh_TW'),
        (system: const Locale('zh', 'MO'), expected: 'zh_TW'),
      ];
      for (final tc in testCases) {
        final loc = resolveAppLocale('system', [tc.system]);
        final key = '${loc.languageCode}_${loc.countryCode}';
        expect(key, tc.expected);
        expect(loc.countryCode, isNotNull);
      }
    });
  });
}
