import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/side_bar.dart';

void main() {
  testWidgets(
    'SideBarRoute with addTopPadding and bottom inset consumes top padding once',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.view.resetPadding);

      tester.view.padding = const FakeViewPadding(top: 40, bottom: 20);
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    SideBarRoute(
                      PopUpWidgetScaffold(
                        title: 'Top Padding Test',
                        body: Container(key: const Key('sidebar-body')),
                      ),
                      width: 500,
                      addTopPadding: true,
                      addBottomPadding: true,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final titleFinder = find.text('Top Padding Test');
      expect(titleFinder, findsOneWidget);
      final bodyFinder = find.byKey(const Key('sidebar-body'));
      expect(bodyFinder, findsOneWidget);

      // Top safe padding is consumed only once by outer SideBarRoute above title bar.
      final titleTop = tester.getTopLeft(titleFinder).dy;
      expect(titleTop, greaterThanOrEqualTo(40));
      expect(titleTop, lessThan(96));

      // Body extends from the title bar bottom to the keyboard/safe-area boundary.
      final bodyRect = tester.getRect(bodyFinder);
      expect(bodyRect.top, 96);
      expect(bodyRect.bottom, 400);
      expect(bodyRect.height, 304);
    },
  );

  testWidgets(
    'SideBarRoute with addBottomPadding=false delegates IME insets to child Scaffold',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.view.resetPadding);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    SideBarRoute(
                      Scaffold(body: Container(key: const Key('sidebar-body'))),
                      width: 500,
                      addTopPadding: false,
                      addBottomPadding: false,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final bodyFinder = find.byKey(const Key('sidebar-body'));
      expect(bodyFinder, findsOneWidget);

      // Record initial body rect before keyboard appears.
      final initialBodyRect = tester.getRect(bodyFinder);

      // Keyboard appears with bottom inset 180.
      const keyboardHeight = 180.0;
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboardHeight);
      await tester.pumpAndSettle();

      // With outer bottom padding disabled, child Scaffold receives IME inset and resizes itself.
      final keyboardBodyRect = tester.getRect(bodyFinder);
      expect(keyboardBodyRect.top, initialBodyRect.top);
      expect(keyboardBodyRect.bottom, 600 - keyboardHeight);
      expect(keyboardBodyRect.height, initialBodyRect.height - keyboardHeight);

      // Dismiss keyboard: child Scaffold body restores to initial geometry.
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(tester.getRect(bodyFinder), initialBodyRect);
    },
  );

  testWidgets(
    'showPopUpWidget retains independent keyboard avoidance without regression',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.view.resetPadding);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  showPopUpWidget(
                    context,
                    PopUpWidgetScaffold(
                      title: 'Popup Dialog Test',
                      body: Container(key: const Key('popup-body')),
                    ),
                  );
                },
                child: const Text('Open Popup'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Popup'));
      await tester.pumpAndSettle();

      final bodyFinder = find.byKey(const Key('popup-body'));
      expect(bodyFinder, findsOneWidget);

      // Record initial body rect before keyboard appears.
      final initialBodyRect = tester.getRect(bodyFinder);

      // Keyboard appears with bottom inset 180.
      const keyboardHeight = 180.0;
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboardHeight);
      await tester.pumpAndSettle();

      // Independent popup keyboard avoidance keeps top edge fixed and stops body at keyboard top.
      final keyboardBodyRect = tester.getRect(bodyFinder);
      expect(keyboardBodyRect.top, initialBodyRect.top);
      expect(keyboardBodyRect.bottom, 600 - keyboardHeight);

      // Dismiss keyboard: popup body rect restores to its initial geometry.
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(tester.getRect(bodyFinder), initialBodyRect);
    },
  );
}
