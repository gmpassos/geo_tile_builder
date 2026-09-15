/// This package's version, as `pubspec.yaml` declares it.
///
/// Dart cannot read `pubspec.yaml` at runtime — it is not an asset, and a
/// compiled executable has no pubspec beside it at all — so a tool that wants
/// to record which version of this package produced an artefact has to be told
/// in code.
///
/// **That is the whole point of it.** A map pack carries the builder version
/// that baked it, and until now that string was typed by hand on a command
/// line: optional, defaulted to empty, and free to disagree with the package
/// that actually did the work. A build recorded as `0.3.0` while 0.4.0 ran is
/// worse than one recorded as nothing, because it looks like an answer.
///
/// Keep it in step with `pubspec.yaml`. `test/version_test.dart` is what stops
/// you forgetting: it reads the pubspec and compares.
library;

/// The version in `pubspec.yaml`, repeated for the code to read.
const geoTileBuilderVersion = '0.4.0';

/// This package, named and versioned the way an artefact records it.
const geoTileBuilderId = 'geo_tile_builder/$geoTileBuilderVersion';
