import 'dart:io';
import 'dart:typed_data';

import 'package:geo_tile_builder/geo_tile_builder.dart';

/// Balneário Camboriú and a margin of ocean around it.
const _minLon = -48.72;
const _minLat = -27.05;
const _maxLon = -48.55;
const _maxLat = -26.94;

/// The coastline runs roughly north–south through the city; everything east of
/// it is the Atlantic.
const _shoreLon = -48.625;

const _minZoom = 10;
const _maxZoom = 15;

/// Builds a real PMTiles archive from synthetic geometry.
///
/// The output opens in any PMTiles reader and renders in MapLibre over
/// `pmtiles://`. It draws an avenue along the shore and fills the sea beside
/// it, which is what makes the writer's two reductions visible: every open-sea
/// tile is byte-identical, so they collapse to a single stored blob and, where
/// they are adjacent along the Hilbert curve, into single directory entries.
///
/// ```sh
/// dart run example/geo_tile_builder_example.dart
/// dart run example/geo_tile_builder_example.dart /tmp/demo.pmtiles
/// ```
Future<void> main(List<String> args) async {
  final output = args.isEmpty ? 'example-demo.pmtiles' : args.first;

  final writer = PmTilesWriter(
    metadata: {
      'name': 'geo_tile_builder demo',
      'description': 'Synthetic tiles built by the package example.',
      // Styles read this to learn which layers and fields exist.
      'vector_layers': [
        {
          'id': 'road',
          'fields': {'class': 'String', 'name': 'String'},
        },
        {
          'id': 'water',
          'fields': {'class': 'String'},
        },
      ],
    },
    minLon: _minLon,
    minLat: _minLat,
    maxLon: _maxLon,
    maxLat: _maxLat,
    centerLon: (_minLon + _maxLon) / 2,
    centerLat: (_minLat + _maxLat) / 2,
    centerZoom: 13,
  );

  const encoder = MvtEncoder();
  var roadTiles = 0;
  var seaTiles = 0;
  Uint8List? seaBytes;

  // Zoom ascending, and within each zoom in tile-id order, so the whole
  // sequence is ascending as the writer requires.
  for (var z = _minZoom; z <= _maxZoom; z++) {
    for (final tile in Mercator.coverage(
      _minLon,
      _minLat,
      _maxLon,
      _maxLat,
      z,
    )) {
      final (west, _, east, _) = Mercator.boundsOf(tile);

      // Wholly offshore: the same sea tile everywhere.
      if (west >= _shoreLon) {
        seaTiles++;
        writer.add(TileId.of(tile), seaBytes ??= encoder.encode(_seaTile));
        continue;
      }

      // Wholly inland: nothing to draw in this demo.
      if (east < _shoreLon) continue;

      roadTiles++;
      writer.add(TileId.of(tile), encoder.encode(_coastTile(tile)));
    }
  }

  final bytes = writer.build();
  await File(output).writeAsBytes(bytes, flush: true);

  final header = PmTilesHeader.fromBytes(bytes);
  stdout
    ..writeln('Wrote $output')
    ..writeln('')
    ..writeln('  zoom range        z${header.minZoom}-${header.maxZoom}')
    ..writeln('  coast tiles       $roadTiles')
    ..writeln('  open-sea tiles    $seaTiles')
    ..writeln('  addressed tiles   ${header.addressedTilesCount}')
    ..writeln('  directory entries ${header.tileEntriesCount}')
    ..writeln('  distinct blobs    ${header.tileContentsCount}')
    ..writeln('  tile data         ${header.tileDataLength} bytes')
    ..writeln('  archive           ${bytes.length} bytes')
    ..writeln('')
    ..writeln(
      'Deduplication and run-length encoding turned '
      '${header.addressedTilesCount} addresses into '
      '${header.tileEntriesCount} entries over '
      '${header.tileContentsCount} stored tiles.',
    );
}

/// A tile that is nothing but open sea, filling its whole extent.
///
/// The ring winds clockwise on screen — positive area with Y pointing down —
/// which is how the format marks an exterior ring rather than a hole.
const _seaTile = MvtTile(
  layers: [
    MvtLayer(
      name: 'water',
      features: [
        MvtFeature(
          type: MvtGeomType.polygon,
          parts: [
            [
              MvtPoint(0, 0),
              MvtPoint(4096, 0),
              MvtPoint(4096, 4096),
              MvtPoint(0, 4096),
            ],
          ],
          attributes: {'class': 'ocean'},
        ),
      ],
    ),
  ],
);

/// A tile straddling the shore: sea to the east, an avenue along the coast.
MvtTile _coastTile(Zxy tile) {
  final (_, south, _, north) = Mercator.boundsOf(tile);

  // The shore as a vertical line in this tile's own coordinates, extended past
  // the tile edges so adjacent tiles join up without a seam.
  final top = Mercator.project(_shoreLon, north, tile);
  final bottom = Mercator.project(_shoreLon, south, tile);

  return MvtTile(
    layers: [
      MvtLayer(
        name: 'water',
        features: [
          MvtFeature(
            type: MvtGeomType.polygon,
            parts: [
              [
                MvtPoint(top.x, -64),
                const MvtPoint(4160, -64),
                const MvtPoint(4160, 4160),
                MvtPoint(bottom.x, 4160),
              ],
            ],
            attributes: const {'class': 'ocean'},
          ),
        ],
      ),
      MvtLayer(
        name: 'road',
        features: [
          MvtFeature(
            id: TileId.of(tile),
            type: MvtGeomType.lineString,
            parts: [
              [MvtPoint(top.x - 96, -64), MvtPoint(bottom.x - 96, 4160)],
            ],
            attributes: const {'class': 'primary', 'name': 'Avenida Atlântica'},
          ),
        ],
      ),
    ],
  );
}
