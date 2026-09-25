import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app_page_route.dart';
import 'package:venera_next/foundation/edge_back_gesture.dart';

void main() {
  var starts = 0;
  var ends = 0;
  var cancels = 0;
  var childDrags = 0;
  var progress = 0.0;

  Future<void> mount(
    WidgetTester tester, {
    bool enabled = true,
    bool scrollable = false,
  }) async {
    starts = ends = cancels = childDrags = 0;
    progress = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: EdgeBackGestureDetector(
          enabled: () => enabled,
          onStart: () => starts++,
          onUpdate: (delta) => progress += delta,
          onEnd: (_) => ends++,
          onCancel: () => cancels++,
          child: GestureDetector(
            onHorizontalDragUpdate: scrollable ? (_) => childDrags++ : null,
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );
  }

  testWidgets('edge back swipe works over horizontally scrollable content', (
    tester,
  ) async {
    await mount(tester, scrollable: true);
    final gesture = await tester.startGesture(const Offset(5, 200));
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(100, 0));
    await gesture.up();
    expect(starts, 1);
    expect(ends, 1);
    expect(childDrags, 0);
  });

  testWidgets('middle swipe stays with child horizontal gestures', (
    tester,
  ) async {
    await mount(tester, scrollable: true);
    await tester.dragFrom(const Offset(200, 200), const Offset(400, 0));
    expect(starts, 0);
    expect(childDrags, greaterThan(0));
  });

  testWidgets(
    'short, vertical, reverse and disabled edge gestures do not start',
    (tester) async {
      await mount(tester);
      for (final delta in [
        const Offset(10, 0),
        const Offset(20, 150),
        const Offset(-80, 0),
      ]) {
        await tester.dragFrom(const Offset(20, 200), delta);
      }
      expect(starts, 0);
      await mount(tester, enabled: false, scrollable: true);
      await tester.dragFrom(const Offset(5, 200), const Offset(400, 0));
      expect(starts, 0);
      expect(childDrags, greaterThan(0));
    },
  );

  testWidgets(
    'edge swipe starts after threshold and cleans up actual pointer IDs',
    (tester) async {
      await mount(tester);
      for (final pointer in [17, 42]) {
        final gesture = await tester.startGesture(
          const Offset(5, 200),
          pointer: pointer,
        );
        await gesture.moveBy(const Offset(12, 0));
        expect(starts, pointer == 17 ? 0 : 1);
        await gesture.moveBy(const Offset(80, 0));
        await gesture.up();
      }
      expect(starts, 2);
      expect(ends, 2);
      expect(progress, closeTo(184 / 800, 0.001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'second finger cancels active swipe and cannot restart until all fingers lift',
    (tester) async {
      await mount(tester);
      final first = await tester.startGesture(const Offset(5, 200), pointer: 7);
      await first.moveBy(const Offset(100, 0));
      final second = await tester.startGesture(
        const Offset(6, 300),
        pointer: 8,
      );
      await second.moveBy(const Offset(100, 0));
      await first.up();
      await second.up();
      expect(starts, 1);
      expect(cancels, 1);
      expect(ends, 0);
      await tester.dragFrom(const Offset(5, 200), const Offset(100, 0));
      expect(starts, 2);
      expect(ends, 1);
    },
  );

  testWidgets('mouse pointer does not trigger edge back gesture', (
    tester,
  ) async {
    await mount(tester);
    final mouseGesture = await tester.startGesture(
      const Offset(5, 200),
      kind: PointerDeviceKind.mouse,
    );
    await mouseGesture.moveBy(const Offset(100, 0));
    await mouseGesture.up();
    expect(starts, 0);
    expect(ends, 0);
  });

  testWidgets('cancel after halfway restores the route instead of popping it', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('home')),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('detail')),
    );
    await tester.pumpAndSettle();
    final animation = AnimationController(vsync: tester, value: 1);
    final controller = IOSBackGestureController(
      animation,
      navigator.currentState!,
    );
    controller.dragUpdate(0.7);
    controller.dragEnd(0, cancelled: true);
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
    expect(animation.value, 1);
    expect(navigator.currentState!.userGestureInProgress, isFalse);
    animation.dispose();
  });

  testWidgets('drag completed past threshold pops the route', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('home')),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('detail')),
    );
    await tester.pumpAndSettle();
    final animation = AnimationController(vsync: tester, value: 1);
    final controller = IOSBackGestureController(
      animation,
      navigator.currentState!,
    );
    controller.dragUpdate(0.6);
    controller.dragEnd(0);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(find.text('detail'), findsNothing);
    expect(navigator.currentState!.userGestureInProgress, isFalse);
    animation.dispose();
  });

  testWidgets('fling gesture with value >= 0.9 does not pop route', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('home')),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('detail')),
    );
    await tester.pumpAndSettle();
    final animation = AnimationController(vsync: tester, value: 0.95);
    final controller = IOSBackGestureController(
      animation,
      navigator.currentState!,
    );
    // High velocity forward fling but value is still >= 0.9
    controller.dragEnd(2.0);
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
    expect(animation.value, 1.0);
    expect(navigator.currentState!.userGestureInProgress, isFalse);
    animation.dispose();
  });

  testWidgets('IOSBackGestureDetector cancels and clears user gesture on dispose', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    var showDetector = true;

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: StatefulBuilder(
          builder: (context, setState) {
            return Scaffold(
              body: showDetector
                  ? IOSBackGestureDetector(
                      gestureWidth: 24,
                      enabledCallback: () => true,
                      onStartPopGesture: () => IOSBackGestureController(
                        AnimationController(vsync: tester, value: 1),
                        navigator.currentState!,
                      ),
                      child: const SizedBox.expand(child: Text('swipe-me')),
                    )
                  : const Text('disposed'),
            );
          },
        ),
      ),
    );

    // Start a gesture to set userGestureInProgress to true
    final gesture = await tester.startGesture(const Offset(5, 200));
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(navigator.currentState!.userGestureInProgress, isTrue);

    // Unmount the detector while gesture was in progress
    showDetector = false;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('disposed')),
      ),
    );
    await tester.pumpAndSettle();

    expect(navigator.currentState!.userGestureInProgress, isFalse);
    await gesture.up();
  });

  testWidgets('root route edge swipe does not pop when canPop is false', (
    tester,
  ) async {
    var popInvoked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EdgeBackGestureDetector(
            enabled: () => false, // root route canPop is false
            onStart: () => popInvoked = true,
            onUpdate: (_) {},
            onEnd: (_) {},
            onCancel: () {},
            child: const SizedBox.expand(child: Text('root-page')),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(5, 200));
    await gesture.moveBy(const Offset(100, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(popInvoked, isFalse);
    expect(find.text('root-page'), findsOneWidget);
  });

  testWidgets('edge back gesture does not start when userGestureInProgress is true', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    var secondGestureStarted = false;

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: EdgeBackGestureDetector(
            enabled: () => !(navigator.currentState?.userGestureInProgress ?? false),
            onStart: () => secondGestureStarted = true,
            onUpdate: (_) {},
            onEnd: (_) {},
            onCancel: () {},
            child: const SizedBox.expand(child: Text('content')),
          ),
        ),
      ),
    );

    // Simulate an ongoing platform gesture
    navigator.currentState!.didStartUserGesture();
    expect(navigator.currentState!.userGestureInProgress, isTrue);

    final gesture = await tester.startGesture(const Offset(5, 200));
    await gesture.moveBy(const Offset(100, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(secondGestureStarted, isFalse);
    navigator.currentState!.didStopUserGesture();
  });
}
