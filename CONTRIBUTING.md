# Contributing

## Setup

```bash
flutter pub get
flutter analyze
flutter test
```

The repository is one Flutter package. Runtime code is under `lib/` and tests
are under `test/`. `example/main.dart` is a source example, not another
package. Do not add native build systems, generated protocol code, or nested
packages.

## Changes

- keep all histories and exported payloads bounded
- keep default features local and read-only; treat UI, errors, and logs as private
- add tests for lifecycle, restart, timeout, limits, and failure paths
- report scope and source when a metric is not process-wide or complete
- use explicit app adapters for routes, state, and network tracking
- update `doc/tools.md` and the inventory test when a gate or tool changes
- update `pubspec.yaml`, `lib/src/version.dart`, and `CHANGELOG.md` together for
  a release
- run `dart format --set-exit-if-changed lib test example`, analyzer, and the
  full test suite before opening a change
- run `dart pub publish --dry-run` before publishing
