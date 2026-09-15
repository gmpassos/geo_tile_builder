import 'dart:io';

import 'package:geo_tile_builder/geo_tile_builder.dart';
import 'package:test/test.dart';

/// The version constant against the pubspec.
///
/// Dart cannot read `pubspec.yaml` at runtime, so the version a build records
/// has to be repeated in code — and a repeated fact is one that drifts. This
/// is the thing that stops it: bump the pubspec without bumping the constant
/// and a map pack claims to have been baked by the previous release, which is
/// worse than claiming nothing, because it looks like an answer.

void main() {
  group('geoTileBuilderVersion', () {
    test('matches the version in pubspec.yaml', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();

      final declared = RegExp(
        r'^version:\s*(\S+)\s*$',
        multiLine: true,
      ).firstMatch(pubspec)?.group(1);

      expect(
        declared,
        isNotNull,
        reason: 'pubspec.yaml has no top-level `version:`',
      );

      expect(
        geoTileBuilderVersion,
        equals(declared),
        reason:
            'lib/src/version.dart says $geoTileBuilderVersion, '
            'pubspec.yaml says $declared',
      );
    });

    test('the artefact id names the package and that version', () {
      // The exact string a pack records, so its shape is pinned rather than
      // assembled differently by each caller.
      expect(
        geoTileBuilderId,
        equals('geo_tile_builder/$geoTileBuilderVersion'),
      );
      expect(geoTileBuilderId, startsWith('geo_tile_builder/'));
    });
  });
}
