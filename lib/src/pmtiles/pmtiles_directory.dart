import 'dart:typed_data';

import '../pbf/pbf_writer.dart';
import 'pmtiles_header.dart';

/// One directory entry: a run of tile ids resolving to one byte range.
///
/// An entry covers ids `tileId .. tileId + runLength - 1`, all served from the
/// same [offset]/[length]. Two different collapses hide behind that:
///
/// * **Run-length encoding** — adjacent ids whose tiles are byte-identical
///   share one entry. On a delivery basemap most of the ocean, and most empty
///   land, is the same empty tile.
/// * **Deduplication** — non-adjacent identical tiles get separate entries
///   pointing at the *same* byte range.
///
/// A [runLength] of `0` is special: the entry is not a tile at all but a
/// pointer to a leaf directory holding further entries.
class PmTilesEntry {
  final int tileId;
  final int offset;
  final int length;
  final int runLength;

  const PmTilesEntry({
    required this.tileId,
    required this.offset,
    required this.length,
    this.runLength = 1,
  });

  /// Whether this entry points at a leaf directory rather than a tile.
  bool get isLeaf => runLength == 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PmTilesEntry &&
          other.tileId == tileId &&
          other.offset == offset &&
          other.length == length &&
          other.runLength == runLength;

  @override
  int get hashCode => Object.hash(tileId, offset, length, runLength);

  @override
  String toString() =>
      'PmTilesEntry(id: $tileId, offset: $offset, length: $length, '
      'run: $runLength)';
}

/// Serialization of PMTiles directories.
///
/// Directories are stored **columnar**: all tile ids, then all run lengths,
/// then all lengths, then all offsets — rather than entry by entry. Grouping
/// like with like is what makes the varints compress: tile ids are written as
/// deltas (so a dense directory is a run of `1`s) and an offset that simply
/// continues the previous byte range is written as `0` instead of a large
/// absolute number.
abstract final class PmTilesDirectory {
  /// Serializes [entries], which must already be sorted by tile id.
  static Uint8List serialize(List<PmTilesEntry> entries) {
    final w = PbfWriter()..writeRawVarint(entries.length);

    var lastId = 0;
    for (final e in entries) {
      w.writeRawVarint(e.tileId - lastId);
      lastId = e.tileId;
    }
    for (final e in entries) {
      w.writeRawVarint(e.runLength);
    }
    for (final e in entries) {
      w.writeRawVarint(e.length);
    }
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      // 0 means "immediately after the previous entry", which is the common
      // case in a clustered archive and saves the whole absolute offset.
      if (i > 0 && e.offset == entries[i - 1].offset + entries[i - 1].length) {
        w.writeRawVarint(0);
      } else {
        w.writeRawVarint(e.offset + 1);
      }
    }

    return w.toBytes();
  }

  /// Parses a directory previously written by [serialize].
  static List<PmTilesEntry> deserialize(Uint8List bytes) {
    final r = _VarintReader(bytes);
    final count = r.read();
    if (count < 0) {
      throw const PmTilesFormatException(
        'directory has a negative entry count',
      );
    }

    final ids = List<int>.filled(count, 0);
    final runs = List<int>.filled(count, 0);
    final lengths = List<int>.filled(count, 0);
    final offsets = List<int>.filled(count, 0);

    var lastId = 0;
    for (var i = 0; i < count; i++) {
      lastId += r.read();
      ids[i] = lastId;
    }
    for (var i = 0; i < count; i++) {
      runs[i] = r.read();
    }
    for (var i = 0; i < count; i++) {
      lengths[i] = r.read();
    }
    for (var i = 0; i < count; i++) {
      final raw = r.read();
      offsets[i] = raw == 0 ? offsets[i - 1] + lengths[i - 1] : raw - 1;
    }

    return [
      for (var i = 0; i < count; i++)
        PmTilesEntry(
          tileId: ids[i],
          offset: offsets[i],
          length: lengths[i],
          runLength: runs[i],
        ),
    ];
  }
}

/// Reads the bare varints a directory is made of.
class _VarintReader {
  final Uint8List _bytes;
  int _pos = 0;

  _VarintReader(this._bytes);

  int read() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _bytes.length) {
        throw const PmTilesFormatException('truncated directory');
      }
      final b = _bytes[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) {
        throw const PmTilesFormatException('malformed varint in directory');
      }
    }
  }
}
