import 'dart:convert';
import 'dart:typed_data';

/// Protobuf wire-format field types.
///
/// Only the four types that appear in the formats this package writes are
/// listed; protobuf's deprecated group types (3 and 4) are not supported.
abstract final class PbfWireType {
  /// `int32`, `int64`, `uint32`, `uint64`, `sint32`, `sint64`, `bool`, `enum`.
  static const int varint = 0;

  /// `fixed64`, `sfixed64`, `double`.
  static const int fixed64 = 1;

  /// `string`, `bytes`, embedded messages, packed repeated fields.
  static const int lengthDelimited = 2;

  /// `fixed32`, `sfixed32`, `float`.
  static const int fixed32 = 5;
}

/// A minimal, allocation-light writer for the protobuf wire format.
///
/// This is the mirror image of the hand-rolled *reader* in `geo_osm_pbf`, and
/// exists for the same reason: the wire format is small and rigidly specified,
/// so encoding it directly is cheaper than taking on `package:protobuf` plus a
/// code-generation step for two schemas that will never change. It keeps this
/// package at **zero runtime dependencies**.
///
/// The writer is deliberately schema-less — it knows field numbers and wire
/// types, not message definitions. Callers spell out the layout, which for the
/// Mapbox Vector Tile schema is a couple of dozen lines:
///
/// ```dart
/// final layer = PbfWriter()
///   ..writeUint(15, 2)          // version
///   ..writeString(1, 'road')    // name
///   ..writeUint(5, 4096);       // extent
///
/// final tile = PbfWriter()..writeMessage(3, layer);
/// final bytes = tile.toBytes();
/// ```
///
/// Nested messages are built as their own [PbfWriter] and handed to
/// [writeMessage], because a length-delimited field must know its payload
/// length before the payload can be written. Building bottom-up costs one extra
/// buffer per nesting level and avoids ever having to back-patch a length.
class PbfWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  PbfWriter();

  /// Number of bytes written so far.
  int get length => _bytes.length;

  /// Whether nothing has been written yet.
  bool get isEmpty => _bytes.isEmpty;

  /// The encoded message.
  ///
  /// Clears the internal buffer, so call this once when the message is
  /// complete.
  Uint8List toBytes() => _bytes.takeBytes();

  /// Writes a bare varint, without a field tag.
  ///
  /// Negative values are sign-extended to 64 bits and therefore always occupy
  /// the full ten bytes — protobuf's `int32`/`int64` behaviour. Use
  /// [writeSInt] (zig-zag) for fields that are frequently negative.
  void writeRawVarint(int value) {
    var v = value;
    while (true) {
      final b = v & 0x7F;
      // Unsigned shift so that negative values terminate after 10 groups
      // rather than looping forever on the sign bits.
      v = v >>> 7;
      if (v == 0) {
        _bytes.addByte(b);
        return;
      }
      _bytes.addByte(b | 0x80);
    }
  }

  /// Zig-zag transform: maps signed values onto unsigned ones so that small
  /// magnitudes stay small regardless of sign.
  ///
  /// `-1` becomes `1`, `1` becomes `2`, and so on. This is what makes
  /// delta-encoded coordinate streams compact.
  static int zigZag(int value) => (value << 1) ^ (value >> 63);

  /// Writes the tag byte(s) identifying [field] and its [wireType].
  void writeTag(int field, int wireType) {
    if (field < 1) {
      throw ArgumentError.value(field, 'field', 'must be >= 1');
    }
    writeRawVarint((field << 3) | wireType);
  }

  /// Writes an unsigned varint field (`uint32`, `uint64`, `bool`, `enum`).
  void writeUint(int field, int value) {
    writeTag(field, PbfWireType.varint);
    writeRawVarint(value);
  }

  /// Writes a signed varint field (`int32`, `int64`) without zig-zag.
  ///
  /// Prefer [writeSInt] unless the schema really says `int32`/`int64`, since
  /// negative values here cost ten bytes.
  void writeInt(int field, int value) => writeUint(field, value);

  /// Writes a zig-zag encoded varint field (`sint32`, `sint64`).
  void writeSInt(int field, int value) {
    writeTag(field, PbfWireType.varint);
    writeRawVarint(zigZag(value));
  }

  /// Writes a `bool` field.
  void writeBool(int field, bool value) => writeUint(field, value ? 1 : 0);

  /// Writes a `double` field (64-bit IEEE 754, little-endian).
  void writeDouble(int field, double value) {
    writeTag(field, PbfWireType.fixed64);
    final d = ByteData(8)..setFloat64(0, value, Endian.little);
    _bytes.add(d.buffer.asUint8List());
  }

  /// Writes a `float` field (32-bit IEEE 754, little-endian).
  void writeFloat(int field, double value) {
    writeTag(field, PbfWireType.fixed32);
    final d = ByteData(4)..setFloat32(0, value, Endian.little);
    _bytes.add(d.buffer.asUint8List());
  }

  /// Writes a UTF-8 `string` field.
  void writeString(int field, String value) =>
      writeBytes(field, utf8.encode(value));

  /// Writes a length-delimited `bytes` field.
  void writeBytes(int field, List<int> value) {
    writeTag(field, PbfWireType.lengthDelimited);
    writeRawVarint(value.length);
    _bytes.add(value);
  }

  /// Writes [message] as an embedded message in [field].
  ///
  /// Consumes [message] — its buffer is taken, not copied.
  void writeMessage(int field, PbfWriter message) =>
      writeBytes(field, message.toBytes());

  /// Writes a packed repeated varint field.
  ///
  /// Nothing is emitted for an empty [values]: a packed field with no elements
  /// is indistinguishable from an absent one, and omitting it is smaller.
  void writePackedUint(int field, List<int> values) {
    if (values.isEmpty) return;
    final payload = PbfWriter();
    for (final v in values) {
      payload.writeRawVarint(v);
    }
    writeBytes(field, payload.toBytes());
  }

  /// Writes a packed repeated zig-zag varint field (`repeated sint64`).
  ///
  /// As with [writePackedUint], an empty [values] emits nothing.
  void writePackedSInt(int field, List<int> values) {
    if (values.isEmpty) return;
    final payload = PbfWriter();
    for (final v in values) {
      payload.writeRawVarint(zigZag(v));
    }
    writeBytes(field, payload.toBytes());
  }
}
