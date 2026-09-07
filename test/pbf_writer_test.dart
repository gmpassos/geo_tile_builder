import 'package:geo_tile_builder/geo_tile_builder.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('PbfWriter', () {
    test('encodes single-byte varints', () {
      final w = PbfWriter()..writeRawVarint(0);
      expect(w.toBytes(), [0]);

      expect((PbfWriter()..writeRawVarint(1)).toBytes(), [1]);
      expect((PbfWriter()..writeRawVarint(127)).toBytes(), [127]);
    });

    test('encodes multi-byte varints little-endian base 128', () {
      // 300 = 0b100101100 -> groups 0101100, 10 -> 0xAC 0x02
      expect((PbfWriter()..writeRawVarint(300)).toBytes(), [0xAC, 0x02]);
    });

    test('encodes negative varints as ten sign-extended bytes', () {
      final bytes = (PbfWriter()..writeRawVarint(-1)).toBytes();
      expect(bytes.length, 10);
      expect(TestPbfReader(bytes).readVarint(), -1);
    });

    test('zig-zag maps small magnitudes to small unsigned values', () {
      expect(PbfWriter.zigZag(0), 0);
      expect(PbfWriter.zigZag(-1), 1);
      expect(PbfWriter.zigZag(1), 2);
      expect(PbfWriter.zigZag(-2), 3);
      expect(PbfWriter.zigZag(2147483647), 4294967294);
    });

    test('writes a tag as (field << 3) | wireType', () {
      final bytes = (PbfWriter()..writeTag(3, PbfWireType.lengthDelimited))
          .toBytes();
      expect(bytes, [(3 << 3) | 2]);
    });

    test('rejects a field number below one', () {
      expect(() => PbfWriter().writeTag(0, 0), throwsArgumentError);
    });

    test('round-trips every scalar field type', () {
      final w = PbfWriter()
        ..writeUint(1, 150)
        ..writeSInt(2, -75)
        ..writeBool(3, true)
        ..writeString(4, 'Balneário Camboriú')
        ..writeDouble(5, 1.5)
        ..writeFloat(6, 0.5);

      final r = TestPbfReader(w.toBytes());

      expect(r.readTag(), (1, PbfWireType.varint));
      expect(r.readVarint(), 150);
      expect(r.readTag(), (2, PbfWireType.varint));
      expect(r.readZigZag(), -75);
      expect(r.readTag(), (3, PbfWireType.varint));
      expect(r.readVarint(), 1);
      expect(r.readTag(), (4, PbfWireType.lengthDelimited));
      expect(r.readString(), 'Balneário Camboriú');
      expect(r.readTag(), (5, PbfWireType.fixed64));
      expect(r.readDouble(), 1.5);
      expect(r.readTag(), (6, PbfWireType.fixed32));
      expect(r.readFloat(), 0.5);
      expect(r.hasMore, isFalse);
    });

    test('nests messages by length prefix', () {
      final inner = PbfWriter()..writeUint(1, 7);
      final outer = PbfWriter()..writeMessage(2, inner);

      final r = TestPbfReader(outer.toBytes());
      expect(r.readTag(), (2, PbfWireType.lengthDelimited));

      final nested = TestPbfReader(r.readLengthDelimited());
      expect(nested.readTag(), (1, PbfWireType.varint));
      expect(nested.readVarint(), 7);
      expect(nested.hasMore, isFalse);
    });

    test('round-trips packed varints', () {
      final w = PbfWriter()..writePackedUint(4, [1, 300, 70000]);
      final r = TestPbfReader(w.toBytes());
      expect(r.readTag(), (4, PbfWireType.lengthDelimited));
      expect(r.readPackedVarints(), [1, 300, 70000]);
    });

    test('omits empty packed fields entirely', () {
      // An empty packed field and an absent one decode identically, so the
      // absent one is strictly smaller.
      expect((PbfWriter()..writePackedUint(4, const [])).toBytes(), isEmpty);
      expect((PbfWriter()..writePackedSInt(4, const [])).toBytes(), isEmpty);
    });

    test('takeBytes empties the writer', () {
      final w = PbfWriter()..writeUint(1, 1);
      expect(w.isEmpty, isFalse);
      w.toBytes();
      expect(w.isEmpty, isTrue);
    });
  });
}
