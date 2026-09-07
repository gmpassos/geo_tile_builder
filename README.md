# geo_tile_builder

[![pub package](https://img.shields.io/pub/v/geo_tile_builder.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/geo_tile_builder)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Dart CI](https://github.com/gmpassos/geo_tile_builder/actions/workflows/dart.yml/badge.svg?branch=master)](https://github.com/gmpassos/geo_tile_builder/actions/workflows/dart.yml)
[![codecov](https://codecov.io/gh/gmpassos/geo_tile_builder/graph/badge.svg)](https://codecov.io/gh/gmpassos/geo_tile_builder)
[![GitHub Tag](https://img.shields.io/github/v/tag/gmpassos/geo_tile_builder?logo=git&logoColor=white)](https://github.com/gmpassos/geo_tile_builder/releases)
[![New Commits](https://img.shields.io/github/commits-since/gmpassos/geo_tile_builder/latest?logo=git&logoColor=white)](https://github.com/gmpassos/geo_tile_builder/network)
[![Last Commits](https://img.shields.io/github/last-commit/gmpassos/geo_tile_builder?logo=git&logoColor=white)](https://github.com/gmpassos/geo_tile_builder/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/gmpassos/geo_tile_builder?logo=github&logoColor=white)](https://github.com/gmpassos/geo_tile_builder/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/gmpassos/geo_tile_builder?logo=github&logoColor=white)](https://github.com/gmpassos/geo_tile_builder)
[![License](https://img.shields.io/github/license/gmpassos/geo_tile_builder?logo=open-source-initiative&logoColor=green)](https://github.com/gmpassos/geo_tile_builder/blob/master/LICENSE)

A high-performance, **schema-agnostic**, **offline-first** vector tile builder
written in **pure Dart**. It encodes [Mapbox Vector Tiles][mvt] and packages them
into [PMTiles][pmtiles] archives — the single-file format MapLibre reads natively
over `pmtiles://` on Android, iOS and the web.

It is the rendering half of a pair: its sibling [`geo_route_finder`][sibling]
compiles the same OpenStreetMap extract into a routing graph, so one download
yields both the map a user sees and the routes drawn on it.

Runs anywhere Dart runs (server, CLI, desktop, mobile, Flutter — any non-web
target, since it uses `dart:io` for files and compression). **No runtime
dependencies.**

[mvt]: https://github.com/mapbox/vector-tile-spec
[pmtiles]: https://docs.protomaps.com/pmtiles/
[sibling]: https://pub.dev/packages/geo_route_finder

## API Documentation

See the [API Documentation][api_doc] for a full list of functions, classes and extensions.

[api_doc]: https://pub.dev/documentation/geo_tile_builder/latest/

## Features

- **Writes real PMTiles v3.** Header, Hilbert-ordered tile ids, columnar
  directories with leaf spilling — verified against an independent reader.
- **Deduplicates and run-length encodes.** Byte-identical tiles are stored once;
  identical *adjacent* tiles collapse into a single directory entry. On a real
  basemap this is the largest single saving.
- **Small by construction.** Attribute keys and values are dictionary-encoded
  per layer, so a schema with a small vocabulary produces small tiles.
- **No dependencies.** The protobuf wire format is written directly; compression
  uses `dart:io` codecs. Nothing is pulled from pub at runtime.
- **Offline first.** Build once, ship the archive, render with no network — the
  case bundled tile packs exist for.

## Architecture

```
Features  ──►  TileSchema  ──►  MvtTile  ──►  MvtEncoder  ──►  tile bytes
(OSM, …)      (classify)      (model)       │                      │
                                            └── PbfWriter ─────────┤
                                                                   ▼
                                       PmTilesWriter  ──►  .pmtiles archive
                                        (dedup, RLE,          │
                                         directories)         ▼
                                                        MapLibre (pmtiles://)
```

Nothing in the encoder depends on OpenStreetMap, or on any particular set of
layers — the tile model is the only contract.

## Getting started

```yaml
dependencies:
  geo_tile_builder: ^0.1.0
```

## Usage

### Encode a vector tile

```dart
import 'package:geo_tile_builder/geo_tile_builder.dart';

final tile = MvtTile(
  layers: [
    MvtLayer(
      name: 'road',
      features: [
        MvtFeature(
          id: 1,
          type: MvtGeomType.lineString,
          parts: [
            [MvtPoint(0, 0), MvtPoint(2048, 2048), MvtPoint(4096, 4096)],
          ],
          attributes: {'class': 'primary', 'name': '5ª Avenida'},
        ),
      ],
    ),
  ],
);

final bytes = const MvtEncoder().encode(tile);
```

Coordinates are tile-local integers over the layer's `extent` (4096 by default),
with the origin at the top-left and Y pointing down.

### Build a PMTiles archive

Tiles must be added in ascending tile-id order — the Hilbert order that
`TileId.fromZxy` produces, which is *not* row-major `x`/`y`.

```dart
final writer = PmTilesWriter(
  metadata: {
    'name': 'Balneário Camboriú',
    'vector_layers': [
      {'id': 'road', 'fields': {'class': 'String', 'name': 'String'}},
    ],
  },
);

writer.addZxy(14, 6185, 9404, bytes);

await writer.writeToFile('bc.pmtiles');
```

### Repackage tiles built elsewhere

Tiles that are already compressed are stored verbatim rather than recompressed,
which is the path for converting an archive produced by another tiler.

```dart
final writer = PmTilesWriter(tileCompression: PmTilesCompression.gzip);
writer.addEncoded(tileId, alreadyGzippedTile);
```

## How it works

### Tile ids

PMTiles numbers tiles along a **Hilbert curve**, zoom by zoom: id 0 is z0, ids
1–4 are z1, ids 5–20 are z2. Consecutive ids are neighbours on the map, so a
viewport's tiles land in a few contiguous byte ranges and a reader fetches them
with very few range requests. `TileId` converts both ways.

### Deduplication and run-length encoding

Every tile added is hashed and compared byte-for-byte against what is already
stored; a repeat reuses the existing byte range. When repeats are also adjacent
in id order, they merge into one directory entry covering the whole run. The
bundled example turns 256 tile addresses into 50 entries over 32 stored tiles,
because 225 of them are the same water tile.

### Directories

Directories are stored columnar — all tile ids, then run lengths, then lengths,
then offsets — with ids delta-encoded and an offset that continues the previous
byte range written as `0`. When the root directory will not fit the format's
16 KiB budget, entries spill into leaf directories, sized by trial so the tree
stays as shallow as the spec allows.

## Performance targets

City-scale pack: `< 50 MB` archive, so it can ship inside an app for offline
use. Encoding is linear in feature count and the writer holds the archive in
memory while building, which is appropriate at city scale.

## Running the example, tests and benchmark

```sh
dart run example/geo_tile_builder_example.dart
dart test
```

## Source

The official source code is [hosted @ GitHub][github_repo]:

- https://github.com/gmpassos/geo_tile_builder

[github_repo]: https://github.com/gmpassos/geo_tile_builder

# Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

# Contribution

Any help from the open-source community is always welcome and needed:

- Found an issue?
    - Please fill a bug report with details.
- Wish a feature?
    - Open a feature request with use cases.
- Are you using and liking the project?
    - Promote the project: create an article, do a post or make a donation.
- Are you a developer?
    - Fix a bug and send a pull request.
    - Implement a new feature.
    - Improve the Unit Tests.
- Have you already helped in any way?
    - **Many thanks from me, the contributors and everybody that uses this project!**

*If you donate 1 hour of your time, you can contribute a lot,
because others will do the same, just be part and start with your 1 hour.*

[tracker]: https://github.com/gmpassos/geo_tile_builder/issues

# Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

[Apache License - Version 2.0][apache_license]

[apache_license]: https://www.apache.org/licenses/LICENSE-2.0.txt
