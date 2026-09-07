import 'dart:io';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';
import 'package:geo_tile_builder/geo_tile_builder.dart';

/// Builds a PMTiles basemap from an OpenStreetMap extract.
///
/// With no arguments it downloads a small region and tiles it. With a path it
/// tiles the extract you already have.
///
/// ```sh
/// dart run example/geo_tile_builder_example.dart
/// dart run example/geo_tile_builder_example.dart --region europe/monaco
/// dart run example/geo_tile_builder_example.dart ./maps/santa-catarina.osm.pbf
/// ```
///
/// The result opens in any PMTiles reader and renders in MapLibre over
/// `pmtiles://` — including from a file on a phone, with no network.
Future<void> main(List<String> args) async {
  final input = await _resolveInput(args);
  if (input == null) return;

  final output = '${input.replaceAll(RegExp(r'\.osm\.pbf$'), '')}.pmtiles';

  // Zoom range matters less than it seems — the low zooms are cheap, because
  // the schema's per-class minimums already keep almost everything out of
  // them. What the archive costs is decided at the top zooms, by how many
  // feature classes the schema admits at all. See benchmark/tile_benchmark.dart.
  const schema = DeliverySchema(minZoom: 8, maxZoom: 15);

  final watch = Stopwatch()..start();
  final report = await TileBuilder(schema: schema).build(
    inputFile: input,
    outputFile: output,
    onProgress: (stage) => stdout.writeln('  $stage ...'),
  );
  watch.stop();

  final perTile = report.tiles == 0
      ? 0
      : (report.archiveBytes / report.tiles).round();

  stdout
    ..writeln('')
    ..writeln('Wrote $output')
    ..writeln('')
    ..writeln(
      '  schema            ${schema.name} '
      '(z${report.minZoom}-${report.maxZoom})',
    )
    ..writeln('  ways kept         ${report.keptWays}')
    ..writeln('  nodes referenced  ${report.referencedNodes}')
    ..writeln('  nodes resolved    ${report.resolvedNodes}')
    ..writeln('  tiles written     ${report.tiles}')
    ..writeln('  features written  ${report.features}')
    ..writeln(
      '  archive           ${_mb(report.archiveBytes)} '
      '($perTile bytes/tile)',
    )
    ..writeln('  built in          ${watch.elapsedMilliseconds} ms');

  if (report.resolvedNodes < report.referencedNodes) {
    final missing = report.referencedNodes - report.resolvedNodes;
    stdout.writeln(
      '\n  note: $missing referenced nodes were not in the extract — '
      'normal for a regional cut, whose ways run past its boundary.',
    );
  }
}

/// Returns the extract to tile, downloading one when no path was given.
Future<String?> _resolveInput(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isNotEmpty && args.first != '--region') {
    final path = positional.first;
    if (!File(path).existsSync()) {
      stderr.writeln('No such file: $path');
      exitCode = 1;
      return null;
    }
    return path;
  }

  final index = args.indexOf('--region');
  final region = index >= 0 && index + 1 < args.length
      ? args[index + 1]
      : 'europe/monaco';

  stdout.writeln('Downloading $region ...');
  final downloader = OsmDownloader(outputDirectory: Directory('./osm-cache'));
  try {
    return await downloader.downloadRegion(
      region: region,
      onProgress: (received, total, url) =>
          stdout.write('\r  ${(received / 1e6).toStringAsFixed(1)} MB'),
    );
  } finally {
    downloader.close();
    stdout.writeln('');
  }
}

String _mb(int bytes) => bytes < 1e6
    ? '${(bytes / 1e3).toStringAsFixed(1)} kB'
    : '${(bytes / 1e6).toStringAsFixed(2)} MB';
