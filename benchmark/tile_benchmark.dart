import 'dart:io';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';
import 'package:geo_tile_builder/geo_tile_builder.dart';

/// Measures what a schema's choices are actually worth.
///
/// The case for this package rests on a claim: a schema written for one product
/// produces a far smaller archive than a general-purpose one, because it is
/// allowed to discard what a general tiler must keep. That claim is testable, so
/// this measures it — the same extract, tiled several ways.
///
/// ```sh
/// dart run benchmark/tile_benchmark.dart path/to/extract.osm.pbf
/// ```
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run benchmark/tile_benchmark.dart <extract.osm.pbf>\n\n'
      'Get one with:\n'
      '  dart run example/geo_tile_builder_example.dart --region europe/monaco',
    );
    exitCode = 64;
    return;
  }

  final input = args.first;
  if (!File(input).existsSync()) {
    stderr.writeln('No such file: $input');
    exitCode = 1;
    return;
  }

  final dir = Directory.systemTemp.createTempSync('gtb_bench_');
  try {
    final results = <_Result>[];

    for (final variant in _variants) {
      final output = '${dir.path}/${variant.label}.pmtiles';
      final watch = Stopwatch()..start();
      final report = await TileBuilder(
        schema: variant.schema,
      ).build(inputFile: input, outputFile: output);
      watch.stop();
      results.add(_Result(variant.label, report, watch.elapsedMilliseconds));
    }

    _print(input, results);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

class _Variant {
  final String label;
  final TileSchema schema;

  const _Variant(this.label, this.schema);
}

const _variants = [
  // The shipped schema.
  _Variant('delivery z8-15', DeliverySchema(minZoom: 8, maxZoom: 15)),
  // The same schema without names — street labels dominate a road layer.
  _Variant(
    'delivery, no names',
    DeliverySchema(minZoom: 8, maxZoom: 15, includeNames: false),
  ),
  // Narrower zoom range: what a rider actually looks at.
  _Variant('delivery z12-15', DeliverySchema(minZoom: 12, maxZoom: 15)),
  // Half the coordinate resolution.
  _Variant(
    'delivery, extent 1024',
    DeliverySchema(minZoom: 8, maxZoom: 15, extent: 1024),
  ),
  // The comparison that matters: everything, everywhere, from z8 — which is
  // what a schema that may not discard anything is forced to do.
  _Variant('keep everything', _KitchenSinkSchema()),
];

/// A deliberately undiscriminating schema, standing in for a general-purpose
/// one: every road type, from the lowest zoom, with every attribute it can
/// reach, and no simplification.
class _KitchenSinkSchema implements TileSchema {
  const _KitchenSinkSchema();

  @override
  String get name => 'everything';

  @override
  int get minZoom => 8;

  @override
  int get maxZoom => 15;

  @override
  int get extent => 4096;

  @override
  List<TileLayerSpec> get layers => const [
    TileLayerSpec(id: 'road', minZoom: 8, maxZoom: 15),
  ];

  @override
  ClassifiedFeature? way(GeoWay way) {
    if (way.nodeIds.length < 2) return null;
    if (way.tags['highway'] == null) return null;
    return ClassifiedFeature(
      layer: 'road',
      type: MvtGeomType.lineString,
      // Everything from the very bottom: no feature earns its zoom.
      minZoom: 8,
      attributes: {for (final e in way.tags.entries) e.key: e.value},
    );
  }

  @override
  ClassifiedFeature? node(GeoTaggedNode node) => null;

  @override
  ClassifiedFeature? relation(GeoRelation relation) => null;

  @override
  int simplificationAt(int zoom) => 0;
}

class _Result {
  final String label;
  final TileBuildReport report;
  final int millis;

  const _Result(this.label, this.report, this.millis);
}

void _print(String input, List<_Result> results) {
  final baseline = results.last.report.archiveBytes;

  stdout
    ..writeln('Extract: $input (${_size(File(input).lengthSync())})')
    ..writeln('')
    ..writeln(
      '${'variant'.padRight(24)}${'tiles'.padLeft(7)}'
      '${'features'.padLeft(10)}${'archive'.padLeft(12)}'
      '${'vs all'.padLeft(9)}${'ms'.padLeft(7)}',
    )
    ..writeln('-' * 69);

  for (final r in results) {
    final ratio = baseline == 0
        ? '-'
        : '${(r.report.archiveBytes / baseline * 100).toStringAsFixed(0)}%';
    stdout.writeln(
      '${r.label.padRight(24)}'
      '${r.report.tiles.toString().padLeft(7)}'
      '${r.report.features.toString().padLeft(10)}'
      '${_size(r.report.archiveBytes).padLeft(12)}'
      '${ratio.padLeft(9)}'
      '${r.millis.toString().padLeft(7)}',
    );
  }

  final delivery = results.first.report.archiveBytes;
  if (baseline > 0 && delivery > 0) {
    stdout
      ..writeln('')
      ..writeln(
        'The delivery schema is ${(baseline / delivery).toStringAsFixed(1)}x '
        'smaller than keeping everything, on the same input.',
      );
  }
}

String _size(int bytes) => bytes < 1e6
    ? '${(bytes / 1e3).toStringAsFixed(1)} kB'
    : '${(bytes / 1e6).toStringAsFixed(2)} MB';
