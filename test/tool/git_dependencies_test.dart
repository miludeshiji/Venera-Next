import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_git_dependencies.dart';

void main() {
  const commit = '0123456789abcdef0123456789abcdef01234567';
  const url = 'https://example.com/reviewed-plugin';
  late Map<String, dynamic> spec;
  late Map<String, dynamic> lock;
  late Map<String, dynamic> inventory;

  Map<String, dynamic> createRepo({
    String dependency = 'plugin',
    String repoUrl = url,
    String pin = commit,
    String status = 'maintained-fork',
    String reason = 'Consumer requires coordinated platform API changes.',
    Map<String, dynamic>? packages,
  }) {
    return <String, dynamic>{
      'dependency': dependency,
      'url': repoUrl,
      'commit': pin,
      'status': status,
      'reason': reason,
      'packages':
          packages ??
          <String, dynamic>{
            'plugin': 'plugin',
            'plugin_platform': 'plugin_platform',
          },
    };
  }

  setUp(() {
    spec = <String, dynamic>{
      'dependencies': <String, dynamic>{
        'plugin': <String, dynamic>{
          'git': <String, dynamic>{'url': url, 'ref': commit, 'path': 'plugin'},
        },
      },
    };
    lock = <String, dynamic>{
      'packages': <String, dynamic>{
        for (final name in ['plugin', 'plugin_platform'])
          name: <String, dynamic>{
            'source': 'git',
            'description': <String, dynamic>{
              'url': url,
              'ref': commit,
              'resolved-ref': commit,
              'path': name,
            },
          },
      },
    };
    inventory = <String, dynamic>{
      'repositories': <dynamic>[createRepo()],
    };
  });

  test('accepts reviewed direct and transitive sources', () {
    expect(checkGitDependencies(spec, lock, inventory), isEmpty);
  });

  test('rejects floating direct refs and changed URLs or paths', () {
    final git = spec['dependencies']['plugin']['git'] as Map<String, dynamic>;
    for (final entry in {
      'ref': 'main',
      'url': 'https://example.com/other',
      'path': 'other',
    }.entries) {
      final original = git[entry.key];
      git[entry.key] = entry.value;
      expect(
        checkGitDependencies(spec, lock, inventory),
        contains(
          'plugin: pubspec does not match the reviewed URL, commit or path',
        ),
        reason: entry.key,
      );
      git[entry.key] = original;
    }
  });

  test(
    'detects URL, pinned ref, resolved SHA and path drift in platform package',
    () {
      final description =
          lock['packages']['plugin_platform']['description']
              as Map<String, dynamic>;
      for (final entry in {
        'url': 'https://example.com/other',
        'ref': 'main',
        'resolved-ref': 'fedcba9876543210fedcba9876543210fedcba98',
        'path': 'other_platform',
      }.entries) {
        final original = description[entry.key];
        description[entry.key] = entry.value;
        expect(
          checkGitDependencies(spec, lock, inventory),
          contains(
            'plugin_platform: locked ${entry.key} differs from reviewed inventory',
          ),
        );
        description[entry.key] = original;
      }
    },
  );

  test('rejects missing platform coverage and unexpected Git packages', () {
    (lock['packages'] as Map<String, dynamic>).remove('plugin_platform');
    (lock['packages'] as Map<String, dynamic>)['unknown'] = <String, dynamic>{
      'source': 'git',
      'description': <String, dynamic>{},
    };
    spec['dev_dependencies'] = <String, dynamic>{
      'tool': <String, dynamic>{'git': 'https://example.com/unreviewed'},
    };
    expect(
      checkGitDependencies(spec, lock, inventory),
      containsAll([
        'plugin_platform: reviewed Git package missing from lockfile',
        'unknown: unexpected transitive Git package',
        'tool: Git dependency has no review record',
      ]),
    );
  });

  test('reviewed platform package cannot become hosted without review', () {
    (lock['packages'] as Map<String, dynamic>)['plugin_platform']['source'] =
        'hosted';
    expect(
      checkGitDependencies(spec, lock, inventory),
      contains('plugin_platform: reviewed Git package missing from lockfile'),
    );
  });

  test('overrides must use the reviewed source', () {
    spec['dependency_overrides'] = <String, dynamic>{
      'plugin': <String, dynamic>{
        'git': <String, dynamic>{'url': url, 'ref': 'main', 'path': 'plugin'},
      },
    };
    expect(
      checkGitDependencies(spec, lock, inventory),
      contains(
        'plugin: pubspec does not match the reviewed URL, commit or path',
      ),
    );
  });

  test('rejects duplicate direct and platform review records', () {
    (inventory['repositories'] as List<dynamic>).add(createRepo());
    expect(
      checkGitDependencies(spec, lock, inventory),
      containsAll([
        'plugin: duplicate direct dependency',
        'plugin_platform: duplicate inventory package',
      ]),
    );
  });

  test('inventory cannot approve abbreviated or floating commits', () {
    final repo =
        (inventory['repositories'] as List<dynamic>).first
            as Map<String, dynamic>;
    for (final invalid in ['main', '0123456', '${commit}0']) {
      repo['commit'] = invalid;
      expect(
        checkGitDependencies(spec, lock, inventory),
        contains('plugin: inventory must pin a full commit SHA'),
      );
    }
  });

  test('review requires retention reason and maintenance status', () {
    final repo =
        (inventory['repositories'] as List<dynamic>).first
            as Map<String, dynamic>;
    repo['reason'] = ' ';
    repo['status'] = 'unreviewed';
    expect(
      checkGitDependencies(spec, lock, inventory),
      contains('plugin: record maintenance status and retention reason'),
    );
  });
}
