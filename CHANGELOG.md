## 0.2.0

- **The OpenStreetMap pipeline.** `.osm.pbf` in, PMTiles basemap out. Verified
  end to end on real data: Monaco tiles at z8-15 into a 157 kB archive in
  ~120 ms, and renders in MapLibre Native from a file in device storage.
- Schema:
  - `TileSchema` (new extension point): decides which source features become
    which layers, with which attributes, from which zoom. This is where a map
    gets small — a schema written for one product may discard what a
    general-purpose tiler is obliged to keep.
  - `TileLayerSpec`, `ClassifiedFeature`.
  - `DeliverySchema`: the bundled worked example. Road network collapsed to
    eight classes, each with a minimum zoom; water for orientation; no POIs,
    no place labels, no buildings, no landuse. `class` and `name` only.
- Geometry:
  - `Mercator`: added `world`, `toLocal` and `tileRangeOfWorld`, so a feature
    is projected once per zoom rather than once per tile.
  - `Simplify`: Ramer–Douglas–Peucker, iterative rather than recursive so a
    way with tens of thousands of vertices cannot blow the stack, plus
    `dedupe` for vertices that collapse under quantisation.
  - `Clip`: Cohen–Sutherland for polylines (returning every run, since a line
    may leave and re-enter a tile) and Sutherland–Hodgman for rings.
  - `ClipRect`, including the tile buffer that stops roads breaking at seams.
- OpenStreetMap:
  - `NodeIdCollector` and `NodeStore`: node coordinates in flat typed arrays at
    16 bytes each, looked up by binary search over sorted ids, rather than the
    boxed `Map<int, GeoNode>` this would otherwise be. An unresolved id reads
    back as null, never as `(0, 0)`.
  - `TileBuilder`: the driver — ways pass, nodes pass, then per zoom project,
    simplify, bin, clip and encode, appending in tile-id order.
  - `TileBuildReport`.
- Benchmark:
  - `benchmark/tile_benchmark.dart` tiles one extract several ways and compares
    them, so the package's central claim is measured rather than asserted. On
    Monaco the delivery schema is **4.2x smaller** than a schema that keeps
    every road from every zoom with every tag (157 kB vs 658 kB).
  - It also corrected two claims that were wrong: dropping street names saves
    about 15%, not "most of it", and narrowing the zoom range saves about 10%,
    because the per-class minimum zooms already keep the low zooms nearly
    empty. What the archive costs is decided at the top zooms.
- `TileBuilder.buffer` now defaults to a 64th of the schema's extent rather
  than a fixed 64 units.
  - **Why:** a fixed buffer is a trap at any other extent. At extent 1024 it
    was a sixteenth of the tile instead of a sixty-fourth, so features spilled
    into neighbouring tiles and *lowering* the extent made the archive bigger.
    The benchmark caught it: extent 1024 now produces 126 kB rather than
    147 kB, and 7,791 features rather than 9,160.
- Dependencies:
  - Added `geo_osm_pbf: ^1.0.0`.
- **Scope change:** MBTiles input is dropped. Reading it means reading SQLite,
  which is at odds with this package having no runtime dependencies, and the
  repackaging path it was meant to serve is already covered by
  `PmTilesWriter.addEncoded`, which accepts tiles from any producer.

## 0.1.0

- Protobuf:
  - `PbfWriter`:
    - Hand-rolled protobuf wire-format writer: varints, zig-zag, packed
      repeated fields, length-delimited fields and nested messages.
    - Keeps the package at **zero runtime dependencies**.
- Mapbox Vector Tiles:
  - `MvtTile`, `MvtLayer`, `MvtFeature`, `MvtPoint`, `MvtGeomType`:
    - The tile model, in tile-local integer coordinates.
  - `MvtGeometryEncoder`:
    - Command/parameter stream encoding with a delta cursor.
    - `ClosePath` for polygon rings, dropping a repeated closing vertex.
    - Drops degenerate parts; rejects deltas beyond the ±(2^31 - 1) range.
    - `doubledSignedArea` for ring winding (exterior is positive with Y down).
  - `MvtEncoder`:
    - Per-layer dictionary encoding of attribute keys and values.
    - Skips layers that contribute no features.
- PMTiles:
  - `TileId`, `Zxy`:
    - Hilbert-curve tile ids, both directions, with per-zoom offsets.
  - `PmTilesHeader`, `PmTilesCompression`, `PmTilesTileType`:
    - The fixed 127-byte v3 header, encode and decode.
  - `PmTilesEntry`, `PmTilesDirectory`:
    - Columnar directory serialization: delta-encoded ids, run lengths,
      lengths, and contiguous offsets written as `0`.
  - `PmTilesWriter`:
    - Clustered archive writer with tile deduplication and run-length
      encoding.
    - Leaf directory spilling when the root exceeds the 16 KiB budget.
    - `add` compresses; `addEncoded` stores already-compressed tiles verbatim,
      for repackaging archives built elsewhere.
    - JSON metadata, bounds and zoom range.
- Tests:
  - Round-trips run through an independent reader and decoder in
    `test/support.dart`, never through the encoder itself.
  - PMTiles archives are additionally verified with the `pmtiles` package in
    strict mode — a **dev dependency only**.
- Example:
  - `geo_tile_builder_example.dart`: builds a real archive and reports how
    deduplication and run-length encoding reduce it.
