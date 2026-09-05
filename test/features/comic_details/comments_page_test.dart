import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/comments_page.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/translations.dart';

ComicSource _buildTestSource({
  CommentsLoader? commentsLoader,
  SendCommentFunc? sendCommentFunc,
  ReplyCommentFunc? replyCommentFunc,
  VoteCommentFunc? voteCommentFunc,
  LikeCommentFunc? likeCommentFunc,
}) {
  return ComicSource(
    'Test Source',
    'test_key',
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    'test.js',
    '',
    '1.0.0',
    commentsLoader,
    sendCommentFunc,
    null,
    null,
    null,
    voteCommentFunc,
    likeCommentFunc,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
    replyCommentFunc: replyCommentFunc,
  );
}

ComicDetails _buildTestComic() {
  return ComicDetails.fromJson({
    'title': 'Test Comic',
    'cover': '',
    'tags': <String, dynamic>{},
    'sourceKey': 'test_key',
    'comicId': 'comic_123',
    'subId': 'sub_456',
  });
}

void main() {
  setUp(() {
    appdata.settings['blockedCommentWords'] = <String>[];
  });

  group('CommentsPage Nested Reply & replyCommentFunc Tests', () {
    testWidgets(
      'calls replyCommentFunc with correct parentId and replyId when replying to secondary comment',
      (tester) async {
        final comic = _buildTestComic();
        final rootComment = Comment.fromJson({
          'id': 'root_001',
          'userName': 'RootUser',
          'content': 'Root comment content',
          'replyCount': 2,
        });
        final secondaryComment = Comment.fromJson({
          'id': 'sec_002',
          'userName': 'SecondaryUser',
          'content': 'Secondary comment content',
        });

        String? capturedComicId;
        String? capturedSubId;
        String? capturedContent;
        String? capturedParentId;
        String? capturedReplyId;
        var commentsLoaderCallCount = 0;

        final source = _buildTestSource(
          commentsLoader: (comicId, subId, page, reply) async {
            commentsLoaderCallCount++;
            return Res([secondaryComment], subData: 1);
          },
          replyCommentFunc: (id, subId, content, parentId, replyId) async {
            capturedComicId = id;
            capturedSubId = subId;
            capturedContent = content;
            capturedParentId = parentId;
            capturedReplyId = replyId;
            return const Res(true);
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CommentsPage(
                data: comic,
                source: source,
                replyComment: rootComment,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        // Root comment and secondary comment should be rendered
        expect(find.text('RootUser'), findsOneWidget);
        expect(find.text('SecondaryUser'), findsOneWidget);

        // Find the reply action icon on the secondary comment
        final replyActionFinder = find.byIcon(Icons.reply);
        expect(replyActionFinder, findsOneWidget);

        // Tap reply action on secondary comment
        await tester.tap(replyActionFinder);
        await tester.pump();

        // Reply target banner should appear
        expect(find.byKey(const Key('reply-target-indicator')), findsOneWidget);
        expect(find.byKey(const Key('reply-cancel-button')), findsOneWidget);

        // Enter text and send
        await tester.enterText(find.byType(TextField), 'Testing precise reply');
        await tester.pump();

        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
        await tester.pump();

        // Verify parameters
        expect(capturedComicId, 'comic_123');
        expect(capturedSubId, 'sub_456');
        expect(capturedContent, 'Testing precise reply');
        expect(capturedParentId, 'root_001');
        expect(capturedReplyId, 'sec_002');

        // On success, text and target should be cleared, and comments reloaded
        final textField = tester.widget<TextField>(find.byType(TextField));
        expect(textField.controller?.text, '');
        expect(find.byKey(const Key('reply-target-indicator')), findsNothing);
        expect(commentsLoaderCallCount, 2);
      },
    );

    testWidgets(
      'calls replyCommentFunc with replyId null when replying to root directly',
      (tester) async {
        final comic = _buildTestComic();
        final rootComment = Comment.fromJson({
          'id': 'root_001',
          'userName': 'RootUser',
          'content': 'Root comment content',
          'replyCount': 1,
        });
        final secondaryComment = Comment.fromJson({
          'id': 'sec_002',
          'userName': 'SecondaryUser',
          'content': 'Secondary comment content',
        });

        String? capturedParentId;
        String? capturedReplyId;

        final source = _buildTestSource(
          commentsLoader: (comicId, subId, page, reply) async {
            return Res([secondaryComment], subData: 1);
          },
          replyCommentFunc: (id, subId, content, parentId, replyId) async {
            capturedParentId = parentId;
            capturedReplyId = replyId;
            return const Res(true);
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CommentsPage(
                data: comic,
                source: source,
                replyComment: rootComment,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        // Send reply without selecting secondary comment
        await tester.enterText(
          find.byType(TextField),
          'Replying to root thread',
        );
        await tester.pump();

        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
        await tester.pump();

        expect(capturedParentId, 'root_001');
        expect(capturedReplyId, isNull);
      },
    );

    testWidgets('cancelling reply target clears target and reverts hint', (
      tester,
    ) async {
      final comic = _buildTestComic();
      final rootComment = Comment.fromJson({
        'id': 'root_001',
        'userName': 'RootUser',
        'content': 'Root content',
      });
      final secondaryComment = Comment.fromJson({
        'id': 'sec_002',
        'userName': 'SecondaryUser',
        'content': 'Secondary content',
      });

      String? capturedReplyId;

      final source = _buildTestSource(
        commentsLoader: (comicId, subId, page, reply) async {
          return Res([secondaryComment], subData: 1);
        },
        replyCommentFunc: (id, subId, content, parentId, replyId) async {
          capturedReplyId = replyId;
          return const Res(true);
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommentsPage(
              data: comic,
              source: source,
              replyComment: rootComment,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Tap reply on secondary comment
      await tester.tap(find.byIcon(Icons.reply));
      await tester.pump();

      expect(find.byKey(const Key('reply-target-indicator')), findsOneWidget);

      // Tap cancel button
      await tester.tap(find.byKey(const Key('reply-cancel-button')));
      await tester.pump();

      // Target indicator should be gone
      expect(find.byKey(const Key('reply-target-indicator')), findsNothing);

      // Now send comment, replyId should be null
      await tester.enterText(find.byType(TextField), 'Root reply after cancel');
      await tester.pump();

      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();

      expect(capturedReplyId, isNull);
    });

    testWidgets('failed send retains text and reply target', (tester) async {
      final comic = _buildTestComic();
      final rootComment = Comment.fromJson({
        'id': 'root_001',
        'userName': 'RootUser',
        'content': 'Root content',
      });
      final secondaryComment = Comment.fromJson({
        'id': 'sec_002',
        'userName': 'SecondaryUser',
        'content': 'Secondary content',
      });

      final messages = <String>[];
      registerShowMessageHandler((context, message) {
        messages.add(message);
      });

      final source = _buildTestSource(
        commentsLoader: (comicId, subId, page, reply) async {
          return Res([secondaryComment], subData: 1);
        },
        replyCommentFunc: (id, subId, content, parentId, replyId) async {
          return const Res.error('Simulated network error');
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommentsPage(
              data: comic,
              source: source,
              replyComment: rootComment,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Select secondary comment
      await tester.tap(find.byIcon(Icons.reply));
      await tester.pump();

      // Enter text
      await tester.enterText(find.byType(TextField), 'Draft reply');
      await tester.pump();

      // Tap send
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();

      // Error message should be shown
      expect(messages, contains('Simulated network error'));

      // Text and reply target must be retained
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller?.text, 'Draft reply');
      expect(find.byKey(const Key('reply-target-indicator')), findsOneWidget);
    });

    testWidgets(
      'legacy source fallback uses sendCommentFunc and does not show precise reply action',
      (tester) async {
        final comic = _buildTestComic();
        final rootComment = Comment.fromJson({
          'id': 'root_001',
          'userName': 'RootUser',
          'content': 'Root content',
        });
        final secondaryComment = Comment.fromJson({
          'id': 'sec_002',
          'userName': 'SecondaryUser',
          'content': 'Secondary content',
        });

        String? capturedId;
        String? capturedSubId;
        String? capturedContent;
        String? capturedReply;

        // Old source with ONLY sendCommentFunc (replyCommentFunc is null)
        final source = _buildTestSource(
          commentsLoader: (comicId, subId, page, reply) async {
            return Res([secondaryComment], subData: 1);
          },
          sendCommentFunc: (id, subId, content, reply) async {
            capturedId = id;
            capturedSubId = subId;
            capturedContent = content;
            capturedReply = reply;
            return const Res(true);
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CommentsPage(
                data: comic,
                source: source,
                replyComment: rootComment,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        // Precise reply action must NOT be shown for secondary comment
        expect(find.byIcon(Icons.reply), findsNothing);

        // Sending in 楼中楼 falls back to sendCommentFunc with rootComment.id
        await tester.enterText(find.byType(TextField), 'Legacy reply');
        await tester.pump();

        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
        await tester.pump();

        expect(capturedId, 'comic_123');
        expect(capturedSubId, 'sub_456');
        expect(capturedContent, 'Legacy reply');
        expect(capturedReply, 'root_001');
      },
    );

    testWidgets(
      'root comments page without replyComment calls sendCommentFunc with null reply',
      (tester) async {
        final comic = _buildTestComic();
        final rootComment = Comment.fromJson({
          'id': 'root_001',
          'userName': 'RootUser',
          'content': 'Root content',
        });

        String? capturedReply;

        final source = _buildTestSource(
          commentsLoader: (comicId, subId, page, reply) async {
            return Res([rootComment], subData: 1);
          },
          sendCommentFunc: (id, subId, content, reply) async {
            capturedReply = reply;
            return const Res(true);
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CommentsPage(
                data: comic,
                source: source,
                replyComment: null,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'Root comment');
        await tester.pump();

        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
        await tester.pump();

        expect(capturedReply, isNull);
      },
    );

    testWidgets(
      'displays replyToUserName structurally without modifying comment content',
      (tester) async {
        final comic = _buildTestComic();
        final commentWithReplyTo = Comment.fromJson({
          'id': 'c_003',
          'userName': 'Bob',
          'content': 'Unmodified body text',
          'replyToUserName': 'Alice',
        });

        final source = _buildTestSource(
          commentsLoader: (comicId, subId, page, reply) async {
            return Res([commentWithReplyTo], subData: 1);
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CommentsPage(data: comic, source: source),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        // replyToUserName is displayed structurally
        expect(find.text('${"Replies".tl} @Alice'), findsOneWidget);

        // The content text is strictly preserved and not concatenated with reply prefix
        expect(find.text('Unmodified body text'), findsOneWidget);
      },
    );

    testWidgets('comments without id do not display unexecutable actions', (
      tester,
    ) async {
      final comic = _buildTestComic();
      final rootComment = Comment.fromJson({
        'id': 'root_001',
        'userName': 'RootUser',
        'content': 'Root content',
      });
      // Secondary comment with id: null, but score and replyCount populated
      final commentWithoutId = Comment.fromJson({
        'userName': 'Anonymous',
        'content': 'No id comment',
        'score': 10,
        'replyCount': 3,
      });

      final source = _buildTestSource(
        commentsLoader: (comicId, subId, page, reply) async {
          return Res([commentWithoutId], subData: 1);
        },
        replyCommentFunc: (id, subId, content, parentId, replyId) async {
          return const Res(true);
        },
        likeCommentFunc: (comicId, subId, commentId, isLike) async {
          return const Res<int?>(null);
        },
        voteCommentFunc: (comicId, subId, commentId, isUp, isCancel) async {
          return const Res<int?>(null);
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommentsPage(
              data: comic,
              source: source,
              replyComment: rootComment,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // None of the interactive actions should be shown for a comment without ID
      expect(find.byIcon(Icons.reply), findsNothing);
      expect(find.byIcon(Icons.favorite), findsNothing);
      expect(find.byIcon(Icons.favorite_border), findsNothing);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      expect(find.byIcon(Icons.arrow_downward), findsNothing);
      expect(find.byIcon(Icons.insert_comment_outlined), findsNothing);
    });

    testWidgets(
      'nested reply page with null root comment id hides bottom input bar',
      (tester) async {
        final comic = _buildTestComic();
        final rootCommentWithoutId = Comment.fromJson({
          'userName': 'RootWithoutId',
          'content': 'Root content without id',
        });

        final source = _buildTestSource(
          commentsLoader: (comicId, subId, page, reply) async {
            return const Res([], subData: 1);
          },
          replyCommentFunc: (id, subId, content, parentId, replyId) async {
            return const Res(true);
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CommentsPage(
                data: comic,
                source: source,
                replyComment: rootCommentWithoutId,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        // Bottom input bar should be hidden because root comment has no ID
        expect(find.byType(TextField), findsNothing);
      },
    );
  });
}
