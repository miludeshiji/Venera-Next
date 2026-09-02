class ComicMetaData {
  const ComicMetaData({
    required this.title,
    required this.author,
    required this.tags,
    this.description = '',
    this.chapters,
    this.bangumiSubjectId,
  });

  factory ComicMetaData.fromJson(Map<String, dynamic> json) {
    final title = json['title'];
    final author = json['author'];
    final tags = json['tags'];
    final description = json['description'] ?? '';
    final chapters = json['chapters'];
    final bangumiSubjectId = json['bangumiSubjectId'];

    if (title is! String) {
      throw const FormatException('metadata.title must be a string');
    }
    if (author is! String) {
      throw const FormatException('metadata.author must be a string');
    }
    if (tags is! List || tags.any((tag) => tag is! String)) {
      throw const FormatException('metadata.tags must be a string array');
    }
    if (description is! String) {
      throw const FormatException('metadata.description must be a string');
    }
    if (chapters != null && chapters is! List) {
      throw const FormatException('metadata.chapters must be an array or null');
    }
    if (bangumiSubjectId != null &&
        (bangumiSubjectId is! int || bangumiSubjectId <= 0)) {
      throw const FormatException(
        'metadata.bangumiSubjectId must be a positive integer or null',
      );
    }

    final result = ComicMetaData(
      title: title,
      author: author,
      tags: List<String>.from(tags),
      description: description,
      chapters: chapters?.map<ComicChapter>((chapter) {
        if (chapter is! Map) {
          throw const FormatException(
            'metadata.chapters entries must be objects',
          );
        }
        return ComicChapter.fromJson(Map<String, dynamic>.from(chapter));
      }).toList(),
      bangumiSubjectId: bangumiSubjectId as int?,
    );
    result.validateChapterRanges();
    return result;
  }

  final String title;
  final String author;
  final List<String> tags;
  final String description;
  final List<ComicChapter>? chapters;
  final int? bangumiSubjectId;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'tags': tags,
    'description': description,
    'chapters': chapters?.map((chapter) => chapter.toJson()).toList(),
    if (bangumiSubjectId != null) 'bangumiSubjectId': bangumiSubjectId,
  };

  void validateChapterRanges({int? pageCount}) {
    var previousEnd = 0;
    for (final chapter in chapters ?? const <ComicChapter>[]) {
      if (chapter.title.trim().isEmpty) {
        throw const FormatException('chapter title must not be empty');
      }
      if (chapter.start < 1) {
        throw const FormatException('chapter start must be at least 1');
      }
      if (chapter.end < chapter.start) {
        throw const FormatException('chapter end must not precede start');
      }
      if (chapter.start <= previousEnd) {
        throw const FormatException(
          'chapter ranges must be ordered and must not overlap',
        );
      }
      if (pageCount != null && chapter.end > pageCount) {
        throw FormatException(
          'chapter range ends at ${chapter.end}, but only $pageCount pages exist',
        );
      }
      previousEnd = chapter.end;
    }
  }
}

class ComicChapter {
  const ComicChapter({
    required this.title,
    required this.start,
    required this.end,
  });

  factory ComicChapter.fromJson(Map<String, dynamic> json) {
    final title = json['title'];
    final start = json['start'];
    final end = json['end'];
    if (title is! String || start is! int || end is! int) {
      throw const FormatException(
        'chapter title, start, and end have invalid types',
      );
    }
    return ComicChapter(title: title, start: start, end: end);
  }

  final String title;
  final int start;
  final int end;

  Map<String, dynamic> toJson() => {'title': title, 'start': start, 'end': end};
}
