import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:geo_tile_builder/geo_tile_builder.dart';

/// Builds a small PMTiles archive from synthetic vector tiles.
///
/// The output is a real archive: MapLibre will render it over `pmtiles://`,
/// and any PMTiles reader will open it. It draws a diagonal "road" across a
/// block of tiles around Balneário Camboriú and fills the rest with open
/// water — which is the point of the demo, because every water tile is
/// byte-identical and so collapses into a single stored blob.
///
/// ```sh
/// dart run example/geo_tile_builder_example.dart
/// dart run example/geo_tile_builder_example.dart /tmp/demo.pmtiles
/// ```
Future<void> main(List<String> args) async {
  final output = args.isEmpty ? 'example-demo.pmtiles' : args.first;

  // A block of z14 tiles covering the city and some ocean around it.
  const zoom = 14;
  const originX = 6180;
  const originY = 9400;
  const span = 16;

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
    minLon: -48.72,
    minLat: -27.05,
    maxLon: -48.55,
    maxLat: -26.94,
  );

  const encoder = MvtEncoder();
  var drawn = 0;

  // Tiles must be added in tile-id order, so collect and sort first — the
  // Hilbert curve does not follow row-major x/y.
  final ids = <int, (int, int)>{};
  for (var x = originX; x < originX + span; x++) {
    for (var y = originY; y < originY + span; y++) {
      ids[TileId.fromZxy(zoom, x, y)] = (x, y);
    }
  }

  for (final id in ids.keys.toList()..sort()) {
    final (x, y) = ids[id]!;
    final tile = _tileFor(x, y);
    if (tile == null) {
      // Open water: the same bytes in every such tile, which is what lets the
      // writer store one copy and run-length encode the addresses.
      writer.add(id, _waterBytes ??= encoder.encode(_waterTile));
      continue;
    }
    drawn++;
    writer.add(id, encoder.encode(tile));
  }

  final bytes = writer.build();
  await File(output).writeAsBytes(bytes, flush: true);

  final header = PmTilesHeader.fromBytes(bytes);
  stdout
    ..writeln('Wrote $output')
    ..writeln('')
    ..writeln('  zoom range        z${header.minZoom}-${header.maxZoom}')
    ..writeln('  tiles with roads  $drawn')
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

/// Encoded once and reused, the way a real pipeline would cache it.
Uint8List? _waterBytes;

/// A tile that is nothing but open water, filling its whole extent.
///
/// The ring winds clockwise on screen — positive area with Y pointing down —
/// which is how the format marks an exterior ring rather than a hole.
const _waterTile = MvtTile(
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

/// Draws a diagonal road through tiles on the `x == y` diagonal of the block,
/// or returns null where there is nothing to draw.
MvtTile? _tileFor(int x, int y) {
  const originX = 6180;
  const originY = 9400;
  final dx = x - originX;
  final dy = y - originY;
  if (dx != dy && dx != dy + 1) return null;

  // A line crossing the tile, with a little jitter so tiles differ from one
  // another and cannot be deduplicated.
  final rnd = Random(x * 31 + y);
  final wobble = rnd.nextInt(512);

  return MvtTile(
    layers: [
      MvtLayer(
        name: 'road',
        features: [
          MvtFeature(
            id: dx + 1,
            type: MvtGeomType.lineString,
            parts: [
              [
                const MvtPoint(0, 0),
                MvtPoint(2048 + wobble, 2048),
                const MvtPoint(4096, 4096),
              ],
            ],
            attributes: const {'class': 'primary', 'name': '5ª Avenida'},
          ),
        ],
      ),
    ],
  );
}
