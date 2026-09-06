# Build and Development

Default Chinese version: [build.zh.md](build.zh.md)

This guide is for developers building, testing, or maintaining VeneraNext from source. For installation and usage, see the root [README](../../README.md).

## Prerequisites

- Flutter `3.41.4`
- Dart `>=3.8.0 <4.0.0`
- JDK `17` for Android builds
- A Rust toolchain; Android builds require the corresponding Android targets
- Native tooling for the target platform, such as Android SDK / NDK, Xcode, Visual Studio, or Linux GTK/WebKit dependencies
- Windows local builds require Developer Mode because the `pdfrx` native assets used by PDF import create symbolic links during the build

Check the Flutter environment first:

```bash
flutter doctor -v
flutter --version
```

## Dependencies

Clone the repository and resolve dependencies from its lock file:

```bash
git clone https://github.com/miludeshiji/Venera-Next.git
cd venera-next
flutter pub get --enforce-lockfile
```

Do not delete or regenerate `pubspec.lock` without understanding the dependency changes.

See [Dependency Governance](dependencies.en.md) for Git fork provenance, pinned commits, and upgrade requirements.

### Critical Version Pin

The project uses `rhttp 0.15.1` and must keep `flutter_rust_bridge 2.11.1`. With an incompatible version, a build may succeed while the resulting application cannot access the network and reports:

```text
flutter_rust_bridge has not been initialized
```

Check the pinned version in PowerShell:

```powershell
Select-String pubspec.lock -Pattern "flutter_rust_bridge" -Context 0,6
```

The result must include:

```yaml
version: "2.11.1"
```

## Quality Checks

Run at least the following before submitting code:

```bash
python .github/scripts/check_structure_imports.py
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

CI runs `flutter test --coverage`, publishes line coverage in the workflow summary, and uploads `coverage/lcov.info`. Coverage is currently a visible baseline rather than a repository-wide hard threshold. Changes to critical behavior still require focused tests.

Pull requests also run `依赖安全审查` and `PR 平台冒烟构建`. Dependency review blocks newly introduced dependencies with high or critical vulnerabilities. Changes to Flutter code, native platform directories, dependencies, build scripts, or workflows run Android Debug and Windows Debug builds; documentation-only changes skip those platform jobs. Dart formatting is checked only for Dart files changed by the current PR, so historical formatting differences do not block new contributions. The `main` branch requires code analysis, dependency review, and the platform smoke-build gate to pass, and direct force-pushes or branch deletion are disabled.

For release-related changes, also run:

```bash
python .github/scripts/release_version.py --check
```

See [Project Structure](../architecture/project_structure.en.md) for module boundaries and entry-point rules.

## Android Build

Place local release signing files at:

```text
android/keystore.jks
android/key.properties
```

Example `android/key.properties`:

```properties
storePassword=your store password
keyPassword=your key password
keyAlias=your key alias
storeFile=../keystore.jks
```

Build the APK:

```bash
flutter pub get --enforce-lockfile
flutter build apk --release --no-pub
```

Artifacts are normally written to `build/app/outputs/apk/release/`.

Signing files and passwords are sensitive and must not be committed.

## Desktop and iOS Builds

With the native toolchain installed on the corresponding operating system, run:

```bash
flutter pub get --enforce-lockfile
flutter build windows --no-pub
flutter build linux --no-pub
flutter build macos --no-pub
```

Use a no-codesign build to validate iOS first:

```bash
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign --no-pub
```

The release workflow builds the Windows installer and portable package; this repository does not maintain winget manifests or public package-manager entries.

## GitHub Actions and Release Versions

Repository workflows handle continuous integration, manual builds, tag releases, and distribution metadata. The release version is maintained centrally in `release.json`:

```json
{
  "version": "1.2.3",
  "build": 123
}
```

Before a release, update `release.json`, then synchronize and validate related files:

```bash
python .github/scripts/release_version.py --write
python .github/scripts/release_version.py --check --tag v1.2.3
```

`pubspec.yaml`, the release tag, and the version section in `CHANGELOG.md` must match `release.json`.

The `代码分析` workflow runs version and structure checks, Python script tests, formatting checks for changed Dart files, `flutter analyze`, the full Dart test suite, and coverage reporting. `依赖安全审查` checks dependencies added or upgraded by a pull request, while `PR 平台冒烟构建` verifies Android and Windows compilation when the changed files can affect platform builds. Before starting multi-platform builds, `完整构建` reuses the same quality workflow. Manual platform builds and tag releases both reuse `.github/workflows/build.yml` so their build definitions cannot drift apart.

Native CI build jobs configure compilation and dependency caching: `sccache` caches Rust and supported native compiler invocations, Cargo caches registry and Git downloads, and Android jobs reuse the Gradle build cache. Jobs print statistics via `sccache --show-stats` upon completion to verify warm-cache hits. Final release packages and installers are always rebuilt and are never reused from cache.

Android release workflows require these repository Secrets:

- `ANDROID_KEYSTORE`: Base64 content of the keystore file
- `ANDROID_KEY_PROPERTIES`: text content of `key.properties`

After a stable release, the AltStore workflow reuses the fixed `automation/update-altstore` branch and creates a pull request. Configure `ALTSTORE_PR_TOKEN` with permission to push a branch and create pull requests in this repository; when it is not configured, the workflow falls back to `WINGET_PKGS_TOKEN`. A missing token or failed PR creation now fails the job instead of reporting success with only an orphan branch.

AI issue checking is disabled by default. After confirming that `API_URL` and `API_KEY` work, set the repository variable `ENABLE_AI_ISSUE_CHECK` to `true`; `ISSUE_CHECK_MODEL` can override the default model. The workflow posts summaries and close recommendations only and never closes an issue automatically.

Never put Secrets, signing files, or real passwords in code, logs, or documentation examples.

## Troubleshooting

### The Build Succeeds but the App Has No Network Access

First confirm that `flutter_rust_bridge` is still `2.11.1` and that dependencies were resolved from the current repository `pubspec.lock`. Do not blindly upgrade dependencies to address initialization failures.

### `flutter_rust_bridge has not been initialized`

This usually means dependency versions have drifted. Restore the repository `pubspec.lock`, confirm the required Flutter version, and run:

```bash
flutter pub get --enforce-lockfile
```

### `Unable to satisfy pubspec.yaml using pubspec.lock`

The Flutter/Dart version or package-source environment usually does not match. Check the Flutter version required by this guide and the output of `flutter doctor -v`; do not immediately delete the lock file.

### Slow Gradle Downloads

You may temporarily use a local Gradle wrapper mirror or configure a network proxy. Environment-specific URLs must not be committed. Before submitting changes, verify that `gradle-wrapper.properties` does not contain local mirror edits.
