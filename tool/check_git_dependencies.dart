import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// Compare all direct and transitive Git packages with the reviewed inventory.
List<String> checkGitDependencies(Map spec, Map lock, Map inventory) {
  final errors = <String>[];
  final expected = <String, Map>{};
  final direct = <String>{};
  final declarations = <dynamic, dynamic>{
    ...?spec['dependencies'] as Map?,
    ...?spec['dev_dependencies'] as Map?,
    ...?spec['dependency_overrides'] as Map?,
  };
  for (final repo in inventory['repositories'] as List) {
    final name = repo['dependency'] as String;
    final commit = repo['commit'] as String;
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
      errors.add('$name: inventory must pin a full commit SHA');
    }
    if (!direct.add(name)) errors.add('$name: duplicate direct dependency');
    if (!['maintained-fork', 'license-review'].contains(repo['status']) ||
        (repo['reason'] as String? ?? '').trim().isEmpty) {
      errors.add('$name: record maintenance status and retention reason');
    }
    final declaration = declarations[name];
    final git = declaration is Map ? declaration['git'] : null;
    final packages = repo['packages'] as Map;
    if (git is! Map ||
        git['url'] != repo['url'] ||
        git['ref'] != commit ||
        (git['path'] ?? '.') != packages[name]) {
      errors.add(
        '$name: pubspec does not match the reviewed URL, commit or path',
      );
    }
    for (final entry in packages.entries) {
      if (expected.containsKey(entry.key)) {
        errors.add('${entry.key}: duplicate inventory package');
      }
      expected[entry.key as String] = {
        'url': repo['url'],
        'ref': commit,
        'resolved-ref': commit,
        'path': entry.value,
      };
    }
  }
  for (final entry in declarations.entries) {
    if (entry.value is Map &&
        (entry.value as Map).containsKey('git') &&
        !direct.contains(entry.key)) {
      errors.add('${entry.key}: Git dependency has no review record');
    }
  }
  final locked = lock['packages'] as Map;
  for (final entry in locked.entries) {
    if (entry.value['source'] != 'git') continue;
    final approved = expected.remove(entry.key);
    if (approved == null) {
      errors.add('${entry.key}: unexpected transitive Git package');
      continue;
    }
    final actual = entry.value['description'] as Map;
    for (final field in approved.keys) {
      if (actual[field] != approved[field]) {
        errors.add(
          '${entry.key}: locked $field differs from reviewed inventory',
        );
      }
    }
  }
  for (final missing in expected.keys) {
    errors.add('$missing: reviewed Git package missing from lockfile');
  }
  return errors;
}

void main() {
  final errors = checkGitDependencies(
    loadYaml(File('pubspec.yaml').readAsStringSync()) as Map,
    loadYaml(File('pubspec.lock').readAsStringSync()) as Map,
    jsonDecode(File('doc/development/git_dependencies.json').readAsStringSync())
        as Map,
  );
  // Build tools must not bypass the application lockfile and review inventory.
  for (final file in Directory(
    '.github/workflows',
  ).listSync().whereType<File>()) {
    if (RegExp(
      r'pub\s+global\s+activate\s+.*(?:-s\s+git|--source[=\s]+git)',
    ).hasMatch(file.readAsStringSync())) {
      errors.add('${file.path}: unreviewed global Git tool installation');
    }
  }
  if (errors.isNotEmpty) {
    stderr.writeln(errors.join('\n'));
    exitCode = 1;
  } else {
    stdout.writeln(
      'Git dependency inventory matches declarations and lockfile.',
    );
  }
}
