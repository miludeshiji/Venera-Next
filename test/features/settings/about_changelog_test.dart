import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/settings.dart';
import 'package:venera_next/foundation/translations.dart';

void main() {
  test('stable users are not notified about prerelease versions', () {
    expect(shouldNotifyUpdateForTesting('1.10.0-rc.2', '1.9.3'), isFalse);
    expect(selectUpdateVersionForTesting(['1.10.0-rc.2'], '1.9.3'), isNull);
    expect(allowsPrereleaseUpdatesForTesting('1.9.3'), isFalse);
  });

  test('prerelease users are notified about newer prereleases', () {
    expect(shouldNotifyUpdateForTesting('1.10.0-rc.2', '1.10.0-rc.1'), isTrue);
    expect(
      selectUpdateVersionForTesting(['1.10.0-rc.2'], '1.10.0-rc.1'),
      '1.10.0-rc.2',
    );
    expect(allowsPrereleaseUpdatesForTesting('1.10.0-rc.1'), isTrue);
  });

  test('stable releases still notify stable users', () {
    expect(shouldNotifyUpdateForTesting('1.10.0', '1.9.3'), isTrue);
    expect(
      selectUpdateVersionForTesting(['1.10.0-rc.2', '1.9.4'], '1.9.3'),
      '1.9.4',
    );
  });

  test('stable channel selects only published stable releases', () {
    final releases = [
      {'tag_name': 'v1.11.0-rc.2', 'draft': false, 'prerelease': true},
      {'tag_name': 'v1.10.1', 'draft': true, 'prerelease': false},
      {'tag_name': 'v1.10.0', 'draft': false, 'prerelease': false},
    ];

    expect(
      selectPublishedReleaseVersionForTesting(
        releases,
        includePrerelease: false,
      ),
      '1.10.0',
    );
    expect(
      selectPublishedReleaseVersionForTesting(
        releases,
        includePrerelease: true,
      ),
      '1.11.0-rc.2',
    );
  });

  group('Changelog Markdown rendering', () {
    setUpAll(() async {
      await AppTranslation.init();
    });

    const changelogFixture =
        '# Venera 2.3.0\n\n'
        '### **核心特性**\n\n'
        '这是一段包含**加粗片段**与`package:venera_next`行内代码的普通句子说明。\n\n'
        '- 一级功能列表项\n'
        '  - 二级嵌套列表项\n'
        '    这是二级列表换行后的续写文本内容\n'
        '    - 三级深层列表项\n\n'
        '硬换行前置行文本  \n'
        '硬换行后置行文本\n\n'
        '- 这是一个用于验证移动端极窄宽度屏幕下长列表文字自动换行而不发生截断并且缩进保持正确对齐的超长列表项内容\n';

    void setupMockChangelog(WidgetTester tester, String content) {
      final messenger = tester.binding.defaultBinaryMessenger;
      final previousHandler = messenger.allMessagesHandler;
      messenger.allMessagesHandler = (channel, handler, message) {
        if (channel == 'flutter/assets' && message != null) {
          final key = utf8.decode(
            message.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          );
          if (key == 'CHANGELOG.md' || key.endsWith('/CHANGELOG.md')) {
            return SynchronousFuture<ByteData>(
              ByteData.sublistView(Uint8List.fromList(utf8.encode(content))),
            );
          }
        }
        if (previousHandler != null) {
          return previousHandler(channel, handler, message);
        }
        if (handler != null) {
          return handler(message);
        }
        return messenger.delegate.send(channel, message);
      };
      rootBundle.evict('CHANGELOG.md');

      addTearDown(() {
        messenger.allMessagesHandler = previousHandler;
        rootBundle.evict('CHANGELOG.md');
      });
    }

    Finder findRichTextContaining(String token) {
      return find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText().contains(token),
      );
    }

    TextSpan? findTextSpan(
      InlineSpan? span,
      bool Function(TextSpan span) predicate,
    ) {
      if (span == null) return null;
      if (span is TextSpan) {
        if (predicate(span)) return span;
        if (span.children != null) {
          for (final child in span.children!) {
            final found = findTextSpan(child, predicate);
            if (found != null) return found;
          }
        }
      }
      return null;
    }

    testWidgets(
      'changelog renders rich markdown formatting without raw syntax, supports nested list indentation, and preserves vertical order',
      (tester) async {
        setupMockChangelog(tester, changelogFixture);
        await tester.pumpWidget(const MaterialApp(home: ChangelogPage()));
        await tester.pumpAndSettle();

        for (final richText in tester.widgetList<RichText>(
          find.byType(RichText),
        )) {
          final plain = richText.text.toPlainText();
          expect(plain, isNot(contains('**')));
          expect(plain, isNot(contains('`')));
        }

        final sentenceFinder = findRichTextContaining('加粗片段');
        expect(sentenceFinder, findsOneWidget);
        final sentenceSpan = tester.widget<RichText>(sentenceFinder).text;

        final boldSpan = findTextSpan(
          sentenceSpan,
          (s) => s.text?.contains('加粗片段') ?? false,
        );
        expect(boldSpan, isNotNull);
        expect(
          boldSpan!.style?.fontWeight,
          anyOf(FontWeight.bold, FontWeight.w700, FontWeight.w800),
        );

        final normalSpan = findTextSpan(
          sentenceSpan,
          (s) => s.text?.contains('这是一段包含') ?? false,
        );
        expect(normalSpan, isNotNull);
        expect(
          normalSpan!.style?.fontWeight,
          isNot(anyOf(FontWeight.bold, FontWeight.w700, FontWeight.w800)),
        );

        final codeSpan = findTextSpan(
          sentenceSpan,
          (s) => s.text?.contains('package:venera_next') ?? false,
        );
        expect(codeSpan, isNotNull);
        expect(codeSpan!.style?.fontFamily, 'monospace');

        final level2Finder = findRichTextContaining('二级嵌套列表项');
        expect(level2Finder, findsOneWidget);
        final level2Text = tester
            .widget<RichText>(level2Finder)
            .text
            .toPlainText();
        expect(level2Text, contains('这是二级列表换行后的续写文本内容'));

        final pLevel1 = tester.getTopLeft(findRichTextContaining('一级功能列表项'));
        final pLevel2 = tester.getTopLeft(level2Finder);
        final pLevel3 = tester.getTopLeft(findRichTextContaining('三级深层列表项'));

        expect(pLevel2.dx, greaterThan(pLevel1.dx));
        expect(pLevel3.dx, greaterThan(pLevel2.dx));

        expect(pLevel2.dy, greaterThan(pLevel1.dy));
        expect(pLevel3.dy, greaterThan(pLevel2.dy));

        final breakParagraph = tester.renderObject<RenderParagraph>(
          findRichTextContaining('硬换行前置行文本'),
        );
        final breakPlain = breakParagraph.text.toPlainText();
        final start1 = breakPlain.indexOf('硬换行前置行文本');
        final boxes1 = breakParagraph.getBoxesForSelection(
          TextSelection(
            baseOffset: start1,
            extentOffset: start1 + '硬换行前置行文本'.length,
          ),
        );
        final start2 = breakPlain.indexOf('硬换行后置行文本');
        final boxes2 = breakParagraph.getBoxesForSelection(
          TextSelection(
            baseOffset: start2,
            extentOffset: start2 + '硬换行后置行文本'.length,
          ),
        );
        expect(boxes1, isNotEmpty);
        expect(boxes2, isNotEmpty);
        expect(boxes2.first.top, greaterThan(boxes1.first.top));
      },
    );

    testWidgets(
      'changelog adapts inline code styling to light and dark theme',
      (tester) async {
        setupMockChangelog(tester, changelogFixture);
        final lightTheme = ThemeData.light();
        await tester.pumpWidget(
          MaterialApp(theme: lightTheme, home: const ChangelogPage()),
        );
        await tester.pumpAndSettle();

        final lightFinder = findRichTextContaining('package:venera_next');
        expect(lightFinder, findsOneWidget);
        final lightSpan = findTextSpan(
          tester.widget<RichText>(lightFinder).text,
          (s) => s.text?.contains('package:venera_next') ?? false,
        );
        expect(lightSpan, isNotNull);
        expect(lightSpan!.style?.fontFamily, 'monospace');
        expect(
          lightSpan.style?.color,
          lightTheme.colorScheme.onSecondaryContainer,
        );
        expect(
          lightSpan.style?.backgroundColor,
          lightTheme.colorScheme.secondaryContainer,
        );

        final darkTheme = ThemeData.dark();
        await tester.pumpWidget(
          MaterialApp(theme: darkTheme, home: const ChangelogPage()),
        );
        await tester.pumpAndSettle();

        final darkFinder = findRichTextContaining('package:venera_next');
        expect(darkFinder, findsOneWidget);
        final darkSpan = findTextSpan(
          tester.widget<RichText>(darkFinder).text,
          (s) => s.text?.contains('package:venera_next') ?? false,
        );
        expect(darkSpan, isNotNull);
        expect(darkSpan!.style?.fontFamily, 'monospace');
        expect(
          darkSpan.style?.color,
          darkTheme.colorScheme.onSecondaryContainer,
        );
        expect(
          darkSpan.style?.backgroundColor,
          darkTheme.colorScheme.secondaryContainer,
        );
        expect(
          darkSpan.style?.color,
          isNot(lightTheme.colorScheme.onSecondaryContainer),
        );
      },
    );

    testWidgets(
      'changelog wraps long text on narrow screens without overflow or broken indentation',
      (tester) async {
        setupMockChangelog(tester, changelogFixture);
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(const MaterialApp(home: ChangelogPage()));
        await tester.pumpAndSettle();

        final longTextFinder = findRichTextContaining('超长列表项内容');
        expect(longTextFinder, findsOneWidget);

        final rect = tester.getRect(longTextFinder);
        expect(rect.left, greaterThanOrEqualTo(0.0));
        expect(rect.right, lessThanOrEqualTo(320.0));
        expect(rect.height, greaterThan(25.0));

        final p1 = tester.getTopLeft(findRichTextContaining('一级功能列表项'));
        final p2 = tester.getTopLeft(findRichTextContaining('二级嵌套列表项'));
        expect(p2.dx, greaterThan(p1.dx));
      },
    );

    testWidgets(
      'changelog supports full page selection and copy through SelectionArea and clipboard',
      (tester) async {
        setupMockChangelog(tester, changelogFixture);
        String? copiedText;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (methodCall) async {
            if (methodCall.method == 'Clipboard.setData') {
              copiedText =
                  (methodCall.arguments as Map<dynamic, dynamic>?)?['text']
                      as String?;
              return null;
            }
            if (methodCall.method == 'Clipboard.getData') {
              return {'text': copiedText};
            }
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });

        await tester.pumpWidget(const MaterialApp(home: ChangelogPage()));
        await tester.pumpAndSettle();

        final selectionAreaFinder = find.byType(SelectionArea);
        expect(selectionAreaFinder, findsOneWidget);

        final selectionState = tester.state<SelectionAreaState>(
          selectionAreaFinder,
        );
        selectionState.selectableRegion.selectAll(
          SelectionChangedCause.keyboard,
        );
        await tester.pump();

        final copyButton = selectionState
            .selectableRegion
            .contextMenuButtonItems
            .firstWhere((item) => item.type == ContextMenuButtonType.copy);
        copyButton.onPressed!();
        await tester.pump();

        expect(copiedText, isNotNull);
        expect(copiedText, contains('Venera 2.3.0'));
        expect(copiedText, contains('核心特性'));
        expect(copiedText, contains('一级功能列表项'));
        expect(copiedText, contains('三级深层列表项'));
        expect(copiedText, contains('package:venera_next'));
        expect(copiedText, isNot(contains('**')));
        expect(copiedText, isNot(contains('`')));
      },
    );
  });
}
