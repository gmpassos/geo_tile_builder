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
