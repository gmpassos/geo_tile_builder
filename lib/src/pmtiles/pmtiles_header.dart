import 'dart:typed_data';

/// Thrown when a PMTiles archive cannot be produced or parsed.
class PmTilesFormatException implements Exception {
  final String message;

  const PmTilesFormatException(this.message);

  @override
  String toString() => 'PmTilesFormatException: $message';
}

/// Compression applied to tile data or to the archive's internal structures.
///
/// Directories and tiles are compressed independently — the header records a
/// scheme for each — because they suit different choices: directories are
/// small and always fetched, tiles are large and often already compact.
enum PmTilesCompression {
  unknown(0),
  none(1),
  gzip(2),
  brotli(3),
  zstd(4);

  final int value;

  const PmTilesCompression(this.value);
}

/// What the tiles in an archive actually are.
enum PmTilesTileType {
  unknown(0),
  mvt(1),
  png(2),
  jpeg(3),
  webp(4),
  avif(5);

  final int value;

  const PmTilesTileType(this.value);
}

/// The fixed 127-byte header that opens every PMTiles v3 archive.
///
/// A reader fetches these bytes first — typically together with the root
/// directory, which is why the spec requires the root to end within the first
/// 16 KiB — and learns from them where everything else lives. Every offset and
/// length is a little-endian `uint64` counted from the start of the file.
///
/// Geographic bounds and the centre are stored as `int32` in units of 1e-7
/// degrees, which resolves to about a centimetre — far finer than any map
/// needs, and the same convention OpenStreetMap uses.
class PmTilesHeader {
  /// Serialized size, fixed by the specification.
  static const int byteLength = 127;

  /// The seven magic bytes that open the file.
  static const String magic = 'PMTiles';

  /// Specification version implemented here.
  static const int specVersion = 3;

  /// Largest a compressed root directory may be, so that the header plus the
  /// root fit inside the first 16384 bytes.
  static const int maxRootDirectoryLength = 16384 - byteLength;

  final int rootDirectoryOffset;
  final int rootDirectoryLength;
  final int metadataOffset;
  final int metadataLength;
  final int leafDirectoryOffset;
  final int leafDirectoryLength;
  final int tileDataOffset;
  final int tileDataLength;

  /// Number of `z/x/y` addresses the archive answers for, counting every id
  /// covered by a run-length-encoded entry.
  final int addressedTilesCount;

  /// Number of directory entries, which is smaller than
  /// [addressedTilesCount] whenever runs were collapsed.
  final int tileEntriesCount;

  /// Number of distinct tile blobs, which is smaller than [tileEntriesCount]
  /// whenever identical tiles were deduplicated.
  final int tileContentsCount;

  /// Whether tile data is stored in tile-id order.
  ///
  /// Readers use this to coalesce range requests, so it is worth preserving.
  final bool clustered;

  final PmTilesCompression internalCompression;
  final PmTilesCompression tileCompression;
  final PmTilesTileType tileType;

  final int minZoom;
  final int maxZoom;

  /// Bounds in degrees.
  final double minLon;
  final double minLat;
  final double maxLon;
  final double maxLat;

  final int centerZoom;
  final double centerLon;
  final double centerLat;

  const PmTilesHeader({
    required this.rootDirectoryOffset,
    required this.rootDirectoryLength,
    required this.metadataOffset,
    required this.metadataLength,
    required this.leafDirectoryOffset,
    required this.leafDirectoryLength,
    required this.tileDataOffset,
    required this.tileDataLength,
    required this.addressedTilesCount,
    required this.tileEntriesCount,
    required this.tileContentsCount,
    required this.minZoom,
    required this.maxZoom,
    this.clustered = true,
    this.internalCompression = PmTilesCompression.gzip,
    this.tileCompression = PmTilesCompression.gzip,
    this.tileType = PmTilesTileType.mvt,
    this.minLon = -180.0,
    this.minLat = -85.0,
    this.maxLon = 180.0,
    this.maxLat = 85.0,
    this.centerZoom = 0,
    this.centerLon = 0.0,
    this.centerLat = 0.0,
  });

  /// Encodes the header.
  Uint8List toBytes() {
    final bytes = Uint8List(byteLength);
    final data = ByteData.sublistView(bytes);

    for (var i = 0; i < magic.length; i++) {
      bytes[i] = magic.codeUnitAt(i);
    }
    bytes[7] = specVersion;

    data
      ..setUint64(8, rootDirectoryOffset, Endian.little)
      ..setUint64(16, rootDirectoryLength, Endian.little)
      ..setUint64(24, metadataOffset, Endian.little)
      ..setUint64(32, metadataLength, Endian.little)
      ..setUint64(40, leafDirectoryOffset, Endian.little)
      ..setUint64(48, leafDirectoryLength, Endian.little)
      ..setUint64(56, tileDataOffset, Endian.little)
      ..setUint64(64, tileDataLength, Endian.little)
      ..setUint64(72, addressedTilesCount, Endian.little)
      ..setUint64(80, tileEntriesCount, Endian.little)
      ..setUint64(88, tileContentsCount, Endian.little);

    bytes[96] = clustered ? 1 : 0;
    bytes[97] = internalCompression.value;
    bytes[98] = tileCompression.value;
    bytes[99] = tileType.value;
    bytes[100] = minZoom;
    bytes[101] = maxZoom;

    data
      ..setInt32(102, _e7(minLon), Endian.little)
      ..setInt32(106, _e7(minLat), Endian.little)
      ..setInt32(110, _e7(maxLon), Endian.little)
      ..setInt32(114, _e7(maxLat), Endian.little);

    bytes[118] = centerZoom;

    data
      ..setInt32(119, _e7(centerLon), Endian.little)
      ..setInt32(123, _e7(centerLat), Endian.little);

    return bytes;
  }

  /// Decodes a header from the first [byteLength] bytes of an archive.
  factory PmTilesHeader.fromBytes(Uint8List bytes) {
    if (bytes.length < byteLength) {
      throw PmTilesFormatException(
        'header needs $byteLength bytes, got ${bytes.length}',
      );
    }
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic.codeUnitAt(i)) {
        throw const PmTilesFormatException('not a PMTiles archive');
      }
    }
    if (bytes[7] != specVersion) {
      throw PmTilesFormatException(
        'unsupported PMTiles version ${bytes[7]}, expected $specVersion',
      );
    }

    final data = ByteData.sublistView(bytes);
    return PmTilesHeader(
      rootDirectoryOffset: data.getUint64(8, Endian.little),
      rootDirectoryLength: data.getUint64(16, Endian.little),
      metadataOffset: data.getUint64(24, Endian.little),
      metadataLength: data.getUint64(32, Endian.little),
      leafDirectoryOffset: data.getUint64(40, Endian.little),
      leafDirectoryLength: data.getUint64(48, Endian.little),
      tileDataOffset: data.getUint64(56, Endian.little),
      tileDataLength: data.getUint64(64, Endian.little),
      addressedTilesCount: data.getUint64(72, Endian.little),
      tileEntriesCount: data.getUint64(80, Endian.little),
      tileContentsCount: data.getUint64(88, Endian.little),
      clustered: bytes[96] != 0,
      internalCompression: _compression(bytes[97]),
      tileCompression: _compression(bytes[98]),
      tileType: _tileType(bytes[99]),
      minZoom: bytes[100],
      maxZoom: bytes[101],
      minLon: _degrees(data.getInt32(102, Endian.little)),
      minLat: _degrees(data.getInt32(106, Endian.little)),
      maxLon: _degrees(data.getInt32(110, Endian.little)),
      maxLat: _degrees(data.getInt32(114, Endian.little)),
      centerZoom: bytes[118],
      centerLon: _degrees(data.getInt32(119, Endian.little)),
      centerLat: _degrees(data.getInt32(123, Endian.little)),
    );
  }

  static int _e7(double degrees) => (degrees * 1e7).round();

  static double _degrees(int e7) => e7 / 1e7;

  static PmTilesCompression _compression(int value) =>
      PmTilesCompression.values.firstWhere(
        (c) => c.value == value,
        orElse: () => PmTilesCompression.unknown,
      );

  static PmTilesTileType _tileType(int value) =>
      PmTilesTileType.values.firstWhere(
        (t) => t.value == value,
        orElse: () => PmTilesTileType.unknown,
      );

  @override
  String toString() =>
      'PmTilesHeader(z$minZoom-$maxZoom, $addressedTilesCount addressed, '
      '$tileEntriesCount entries, $tileContentsCount contents)';
}
