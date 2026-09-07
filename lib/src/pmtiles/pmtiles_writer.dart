import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pmtiles_directory.dart';
import 'pmtiles_header.dart';
import 'tile_id.dart';

/// Builds a PMTiles v3 archive.
///
/// Tiles are added in ascending tile-id order — [TileId.fromZxy] produces that
/// order from `z/x/y` — and the writer lays them out contiguously, so the
/// archive is *clustered* and a reader can serve a viewport with very few range
/// requests.
///
/// Two reductions happen automatically as tiles arrive:
///
/// * **Deduplication.** A tile byte-identical to one already written reuses its
///   byte range instead of being stored again. On a real basemap this is the
///   single biggest saving — every empty ocean tile is the same tile.
/// * **Run-length encoding.** When those identical tiles are also *adjacent* in
///   id order, they collapse into one directory entry rather than one each.
///
/// The archive is assembled in memory and emitted by [build] or [writeToFile].
/// That is appropriate for the city-sized packs this package targets; a
/// continent-sized archive would want a streaming writer, which is deliberately
/// left until there is a reason to build one.
///
/// ```dart
/// final writer = PmTilesWriter(metadata: {'name': 'Balneário Camboriú'});
/// writer.addZxy(14, 6185, 9404, mvtBytes);
/// await writer.writeToFile('bc.pmtiles');
/// ```
class PmTilesWriter {
  /// What the tiles are. Written to the header so readers know how to render.
  final PmTilesTileType tileType;

  /// Compression applied to each tile by [add].
  final PmTilesCompression tileCompression;

  /// Compression applied to directories and metadata.
  final PmTilesCompression internalCompression;

  /// Free-form metadata, serialized as JSON.
  ///
  /// For vector tiles this should carry a `vector_layers` array; some clients
  /// need it to know what a style may reference.
  final Map<String, Object?> metadata;

  final double minLon;
  final double minLat;
  final double maxLon;
  final double maxLat;
  final double? centerLon;
  final double? centerLat;
  final int? centerZoom;

  /// Unique tile blobs, in the order they were first seen.
  final List<Uint8List> _blobs = [];

  /// Byte offset of each blob, relative to the start of the tile data section.
  final List<int> _blobOffsets = [];

  /// Hash of a blob to the indices of blobs sharing that hash. Candidates are
  /// compared byte-for-byte, so a collision costs time, never correctness.
  final Map<int, List<int>> _blobsByHash = {};

  final List<PmTilesEntry> _entries = [];

  int _tileDataLength = 0;
  int _addressedTiles = 0;
  int _lastTileId = -1;
  int _minZoom = TileId.maxZoom;
  int _maxZoom = 0;

  PmTilesWriter({
    this.tileType = PmTilesTileType.mvt,
    this.tileCompression = PmTilesCompression.gzip,
    this.internalCompression = PmTilesCompression.gzip,
    this.metadata = const {},
    this.minLon = -180.0,
    this.minLat = -85.0,
    this.maxLon = 180.0,
    this.maxLat = 85.0,
    this.centerLon,
    this.centerLat,
    this.centerZoom,
  });

  /// Number of directory entries so far.
  int get entryCount => _entries.length;

  /// Number of distinct tile blobs stored so far.
  int get contentCount => _blobs.length;

  /// Number of tile addresses accepted so far, including deduplicated ones.
  int get addressedTileCount => _addressedTiles;

  /// Total size of the stored tile data.
  int get tileDataLength => _tileDataLength;

  /// Adds an uncompressed tile, applying [tileCompression].
  ///
  /// Empty tiles are ignored: an absent tile and a zero-byte tile render the
  /// same, and the absent one costs nothing.
  void add(int tileId, List<int> tile) {
    if (tile.isEmpty) return;
    addEncoded(tileId, _compress(tile, tileCompression));
  }

  /// Adds a tile that is **already** in [tileCompression] form.
  ///
  /// This is the path for repackaging tiles produced elsewhere — an MBTiles
  /// archive from another tiler, for instance — where recompressing would be
  /// wasted work.
  void addEncoded(int tileId, List<int> tile) {
    if (tile.isEmpty) return;
    if (tileId <= _lastTileId) {
      throw PmTilesFormatException(
        'tiles must be added in ascending id order; got $tileId after '
        '$_lastTileId',
      );
    }

    final bytes = tile is Uint8List ? tile : Uint8List.fromList(tile);
    final zoom = TileId.toZxy(tileId).z;
    if (zoom < _minZoom) _minZoom = zoom;
    if (zoom > _maxZoom) _maxZoom = zoom;

    final index = _intern(bytes);
    final offset = _blobOffsets[index];
    final length = _blobs[index].length;

    // Collapse into the previous entry when this tile continues its run: same
    // bytes, next id along.
    if (_entries.isNotEmpty) {
      final last = _entries.last;
      if (last.offset == offset &&
          last.length == length &&
          tileId == last.tileId + last.runLength) {
        _entries[_entries.length - 1] = PmTilesEntry(
          tileId: last.tileId,
          offset: last.offset,
          length: last.length,
          runLength: last.runLength + 1,
        );
        _lastTileId = tileId;
        _addressedTiles++;
        return;
      }
    }

    _entries.add(PmTilesEntry(tileId: tileId, offset: offset, length: length));
    _lastTileId = tileId;
    _addressedTiles++;
  }

  /// Adds an uncompressed tile addressed by `z/x/y`.
  void addZxy(int z, int x, int y, List<int> tile) =>
      add(TileId.fromZxy(z, x, y), tile);

  /// Stores [bytes] if new, and returns the index of the blob holding them.
  int _intern(Uint8List bytes) {
    final hash = _hash(bytes);
    final candidates = _blobsByHash.putIfAbsent(hash, () => []);

    for (final index in candidates) {
      if (_sameBytes(_blobs[index], bytes)) return index;
    }

    final index = _blobs.length;
    _blobs.add(bytes);
    _blobOffsets.add(_tileDataLength);
    _tileDataLength += bytes.length;
    candidates.add(index);
    return index;
  }

  /// FNV-1a over the blob. Only a bucket key — equality is decided by
  /// [_sameBytes], so collisions are harmless.
  static int _hash(Uint8List bytes) {
    var h = 0xcbf29ce484222325;
    for (final b in bytes) {
      h = (h ^ b) * 0x100000001b3;
      h &= 0xFFFFFFFFFFFFFFFF;
    }
    return h;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Uint8List _compress(List<int> bytes, PmTilesCompression compression) =>
      switch (compression) {
        PmTilesCompression.none =>
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        // Level 9: this runs once at build time and the result ships to every
        // device, so size beats speed.
        PmTilesCompression.gzip => Uint8List.fromList(
          GZipCodec(level: 9).encode(bytes),
        ),
        _ => throw PmTilesFormatException(
          'compression ${compression.name} is not supported by this writer',
        ),
      };

  /// Assembles the archive.
  Uint8List build() {
    final metadataBytes = _compress(
      utf8.encode(jsonEncode(metadata)),
      internalCompression,
    );

    final (rootBytes, leafBytes) = _buildDirectories();

    const rootOffset = PmTilesHeader.byteLength;
    final metadataOffset = rootOffset + rootBytes.length;
    final leafOffset = metadataOffset + metadataBytes.length;
    final tileDataOffset = leafOffset + leafBytes.length;

    final header = PmTilesHeader(
      rootDirectoryOffset: rootOffset,
      rootDirectoryLength: rootBytes.length,
      metadataOffset: metadataOffset,
      metadataLength: metadataBytes.length,
      leafDirectoryOffset: leafOffset,
      leafDirectoryLength: leafBytes.length,
      tileDataOffset: tileDataOffset,
      tileDataLength: _tileDataLength,
      addressedTilesCount: _addressedTiles,
      tileEntriesCount: _entries.length,
      tileContentsCount: _blobs.length,
      clustered: true,
      internalCompression: internalCompression,
      tileCompression: tileCompression,
      tileType: tileType,
      minZoom: _entries.isEmpty ? 0 : _minZoom,
      maxZoom: _entries.isEmpty ? 0 : _maxZoom,
      minLon: minLon,
      minLat: minLat,
      maxLon: maxLon,
      maxLat: maxLat,
      centerZoom: centerZoom ?? (_entries.isEmpty ? 0 : _minZoom),
      centerLon: centerLon ?? (minLon + maxLon) / 2,
      centerLat: centerLat ?? (minLat + maxLat) / 2,
    );

    final out = BytesBuilder(copy: false)
      ..add(header.toBytes())
      ..add(rootBytes)
      ..add(metadataBytes)
      ..add(leafBytes);
    for (final blob in _blobs) {
      out.add(blob);
    }
    return out.takeBytes();
  }

  /// Writes the archive to [path].
  Future<void> writeToFile(String path) =>
      File(path).writeAsBytes(build(), flush: true);

  /// Produces the root directory, plus the leaf directory section when the
  /// root alone would not fit in the header's 16 KiB budget.
  ///
  /// Leaves are sized by trial: start small and grow until the root fits. Each
  /// attempt is cheap next to building the tiles themselves, and the result is
  /// the shallowest tree that satisfies the spec — which is what keeps a
  /// reader to one extra fetch at most.
  (Uint8List, Uint8List) _buildDirectories() {
    final flat = _compress(
      PmTilesDirectory.serialize(_entries),
      internalCompression,
    );
    if (flat.length <= PmTilesHeader.maxRootDirectoryLength) {
      return (flat, Uint8List(0));
    }

    var leafSize = 4096;
    while (true) {
      final rootEntries = <PmTilesEntry>[];
      final leaves = BytesBuilder(copy: false);

      for (var i = 0; i < _entries.length; i += leafSize) {
        final end = (i + leafSize).clamp(0, _entries.length);
        final chunk = _entries.sublist(i, end);
        final leaf = _compress(
          PmTilesDirectory.serialize(chunk),
          internalCompression,
        );
        rootEntries.add(
          PmTilesEntry(
            tileId: chunk.first.tileId,
            offset: leaves.length,
            length: leaf.length,
            // A run length of zero marks a pointer to a leaf directory.
            runLength: 0,
          ),
        );
        leaves.add(leaf);
      }

      final root = _compress(
        PmTilesDirectory.serialize(rootEntries),
        internalCompression,
      );
      if (root.length <= PmTilesHeader.maxRootDirectoryLength) {
        return (root, leaves.takeBytes());
      }

      leafSize = (leafSize * 1.2).ceil();
    }
  }
}
