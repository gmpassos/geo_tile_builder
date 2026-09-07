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
