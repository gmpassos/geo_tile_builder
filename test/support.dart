import 'dart:convert';
import 'dart:typed_data';

import 'package:geo_tile_builder/geo_tile_builder.dart';

/// A minimal protobuf wire reader, used to verify what [PbfWriter] produced.
///
/// This is deliberately an *independent* implementation rather than a shared
/// one: a round-trip through the same buggy code proves nothing. It reads the
/// wire format straight from the spec.
class TestPbfReader {
  final Uint8List bytes;
  int _pos = 0;

  TestPbfReader(this.bytes);

  bool get hasMore => _pos < bytes.length;

  int get position => _pos;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= bytes.length) {
        throw StateError('truncated varint');
      }
      final b = bytes[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) throw StateError('varint too long');
    }
  }

  /// Reads a tag, returning `(field, wireType)`.
  (int, int) readTag() {
    final key = readVarint();
    return (key >> 3, key & 0x7);
  }

  int readZigZag() {
    final n = readVarint();
    return (n >> 1) ^ (-(n & 1));
  }

  Uint8List readLengthDelimited() {
    final len = readVarint();
    final out = Uint8List.sublistView(bytes, _pos, _pos + len);
    _pos += len;
    return out;
  }

  String readString() => utf8.decode(readLengthDelimited());

  double readDouble() {
    final d = ByteData.sublistView(bytes, _pos, _pos + 8);
    _pos += 8;
    return d.getFloat64(0, Endian.little);
  }

  double readFloat() {
    final d = ByteData.sublistView(bytes, _pos, _pos + 4);
    _pos += 4;
    return d.getFloat32(0, Endian.little);
  }

  List<int> readPackedVarints() {
    final payload = readLengthDelimited();
    final r = TestPbfReader(payload);
    final out = <int>[];
    while (r.hasMore) {
      out.add(r.readVarint());
    }
    return out;
  }

  /// Skips a field of [wireType], so unknown fields never derail a decode.
  void skip(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        _pos += 8;
      case 2:
        _pos += readVarint();
      case 5:
        _pos += 4;
      default:
        throw StateError('unsupported wire type $wireType');
    }
  }
}

/// Decodes Mapbox Vector Tile bytes back into the package's model.
///
/// Independent of [MvtEncoder] — this exists so a round-trip test actually
/// tests something.
MvtTile decodeMvtTile(Uint8List bytes) {
  final layers = <MvtLayer>[];
  final r = TestPbfReader(bytes);
  while (r.hasMore) {
    final (field, wire) = r.readTag();
    if (field == 3 && wire == 2) {
      layers.add(_decodeLayer(r.readLengthDelimited()));
    } else {
      r.skip(wire);
    }
  }
  return MvtTile(layers: layers);
}

MvtLayer _decodeLayer(Uint8List bytes) {
  var name = '';
  var extent = 4096;
  final keys = <String>[];
  final values = <Object?>[];
  final rawFeatures = <Uint8List>[];

  final r = TestPbfReader(bytes);
  while (r.hasMore) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 1:
        name = r.readString();
      case 2:
        rawFeatures.add(r.readLengthDelimited());
      case 3:
        keys.add(r.readString());
      case 4:
        values.add(_decodeValue(r.readLengthDelimited()));
      case 5:
        extent = r.readVarint();
      case 15:
        r.readVarint(); // version
      default:
        r.skip(wire);
    }
  }

  return MvtLayer(
    name: name,
    extent: extent,
    features: [for (final f in rawFeatures) _decodeFeature(f, keys, values)],
  );
}

Object? _decodeValue(Uint8List bytes) {
  final r = TestPbfReader(bytes);
  while (r.hasMore) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 1:
        return r.readString();
      case 2:
        return r.readFloat();
      case 3:
        return r.readDouble();
      case 4:
      case 5:
        return r.readVarint();
      case 6:
        return r.readZigZag();
      case 7:
        return r.readVarint() != 0;
      default:
        r.skip(wire);
    }
  }
  return null;
}

MvtFeature _decodeFeature(
  Uint8List bytes,
  List<String> keys,
  List<Object?> values,
) {
  int? id;
  var type = MvtGeomType.unknown;
  var tags = const <int>[];
  var geometry = const <int>[];

  final r = TestPbfReader(bytes);
  while (r.hasMore) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 1:
        id = r.readVarint();
      case 2:
        tags = r.readPackedVarints();
      case 3:
        // Read once: a predicate that calls readVarint() would consume one
        // varint per enum candidate.
        final raw = r.readVarint();
        type = MvtGeomType.values.firstWhere(
          (t) => t.value == raw,
          orElse: () => MvtGeomType.unknown,
        );
      case 4:
        geometry = r.readPackedVarints();
      default:
        r.skip(wire);
    }
  }

  final attributes = <String, Object?>{};
  for (var i = 0; i + 1 < tags.length; i += 2) {
    attributes[keys[tags[i]]] = values[tags[i + 1]];
  }

  return MvtFeature(
    id: id,
    type: type,
    parts: decodeMvtGeometry(type, geometry),
    attributes: attributes,
  );
}

/// Replays a command stream back into point runs.
List<List<MvtPoint>> decodeMvtGeometry(MvtGeomType type, List<int> geometry) {
  final parts = <List<MvtPoint>>[];
  List<MvtPoint>? current;
  var cx = 0, cy = 0;
  var i = 0;

  int zag(int n) => (n >> 1) ^ (-(n & 1));

  while (i < geometry.length) {
    final cmd = geometry[i++];
    final id = cmd & 0x7;
    final count = cmd >> 3;

    switch (id) {
      case MvtGeometryEncoder.commandMoveTo:
        for (var k = 0; k < count; k++) {
          cx += zag(geometry[i++]);
          cy += zag(geometry[i++]);
          // A multipoint is one run; every other type starts a new run per
          // MoveTo.
          if (type == MvtGeomType.point) {
            (current ??= (parts..add([])).last).add(MvtPoint(cx, cy));
          } else {
            current = [MvtPoint(cx, cy)];
            parts.add(current);
          }
        }
      case MvtGeometryEncoder.commandLineTo:
        for (var k = 0; k < count; k++) {
          cx += zag(geometry[i++]);
          cy += zag(geometry[i++]);
          current!.add(MvtPoint(cx, cy));
        }
      case MvtGeometryEncoder.commandClosePath:
        // Rings are represented unclosed on both sides of the round trip.
        break;
      default:
        throw StateError('unknown geometry command $id');
    }
  }

  return parts;
}
