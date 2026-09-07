import 'dart:io';
import 'dart:typed_data';

import 'package:geo_tile_builder/geo_tile_builder.dart';
import 'package:pmtiles/pmtiles.dart' as oracle;
import 'package:test/test.dart';

/// A distinct, recognisable tile payload for index [i].
Uint8List _tile(int i) =>
    Uint8List.fromList([0x1f, i & 0xFF, (i >> 8) & 0xFF, (i >> 16) & 0xFF]);

/// Opens an archive with the independent `pmtiles` reader.
///
/// `strict` turns on that package's own header and directory invariant checks,
/// which is the whole reason it is here: it agrees with the spec, not with us.
Future<oracle.PmTilesArchive> _open(Uint8List bytes) =>
    oracle.PmTilesArchive.fromBytes(bytes, strict: true);

void main() {
  group('PmTilesHeader', () {
    test('is exactly 127 bytes, opening with the magic and version', () {
      const header = PmTilesHeader(
        rootDirectoryOffset: 127,
        rootDirectoryLength: 10,
        metadataOffset: 137,
        metadataLength: 2,
        leafDirectoryOffset: 139,
        leafDirectoryLength: 0,
        tileDataOffset: 139,
        tileDataLength: 5,
        addressedTilesCount: 1,
        tileEntriesCount: 1,
        tileContentsCount: 1,
        minZoom: 0,
        maxZoom: 14,
      );

      final bytes = header.toBytes();
      expect(bytes, hasLength(PmTilesHeader.byteLength));
      expect(String.fromCharCodes(bytes.sublist(0, 7)), 'PMTiles');
      expect(bytes[7], 3);
    });

    test('round-trips every field', () {
      const header = PmTilesHeader(
        rootDirectoryOffset: 127,
        rootDirectoryLength: 4096,
        metadataOffset: 4223,
        metadataLength: 128,
        leafDirectoryOffset: 4351,
        leafDirectoryLength: 512,
        tileDataOffset: 4863,
        tileDataLength: 999999,
        addressedTilesCount: 12345,
        tileEntriesCount: 6789,
        tileContentsCount: 1011,
        minZoom: 3,
        maxZoom: 16,
        clustered: true,
        internalCompression: PmTilesCompression.gzip,
        tileCompression: PmTilesCompression.none,
        tileType: PmTilesTileType.mvt,
        minLon: -48.7,
        minLat: -27.1,
        maxLon: -48.5,
        maxLat: -26.9,
        centerZoom: 12,
        centerLon: -48.6,
        centerLat: -27.0,
      );

      final decoded = PmTilesHeader.fromBytes(header.toBytes());

      expect(decoded.rootDirectoryOffset, 127);
      expect(decoded.rootDirectoryLength, 4096);
      expect(decoded.metadataOffset, 4223);
      expect(decoded.metadataLength, 128);
      expect(decoded.leafDirectoryOffset, 4351);
      expect(decoded.leafDirectoryLength, 512);
      expect(decoded.tileDataOffset, 4863);
      expect(decoded.tileDataLength, 999999);
      expect(decoded.addressedTilesCount, 12345);
      expect(decoded.tileEntriesCount, 6789);
      expect(decoded.tileContentsCount, 1011);
      expect(decoded.clustered, isTrue);
      expect(decoded.internalCompression, PmTilesCompression.gzip);
      expect(decoded.tileCompression, PmTilesCompression.none);
      expect(decoded.tileType, PmTilesTileType.mvt);
      expect(decoded.minZoom, 3);
      expect(decoded.maxZoom, 16);
      expect(decoded.centerZoom, 12);
      // Bounds are stored at 1e-7 degrees, so they survive to well under a
      // metre.
      expect(decoded.minLon, closeTo(-48.7, 1e-7));
      expect(decoded.maxLat, closeTo(-26.9, 1e-7));
      expect(decoded.centerLat, closeTo(-27.0, 1e-7));
    });

    test('rejects bytes that are not a PMTiles archive', () {
      final junk = Uint8List(PmTilesHeader.byteLength);
      expect(
        () => PmTilesHeader.fromBytes(junk),
        throwsA(isA<PmTilesFormatException>()),
      );
    });

    test('rejects a truncated header', () {
      expect(
        () => PmTilesHeader.fromBytes(Uint8List(10)),
        throwsA(isA<PmTilesFormatException>()),
      );
    });
  });

  group('PmTilesDirectory', () {
    test('round-trips entries', () {
      const entries = [
        PmTilesEntry(tileId: 5, offset: 0, length: 100),
        PmTilesEntry(tileId: 6, offset: 100, length: 250, runLength: 3),
        PmTilesEntry(tileId: 20, offset: 0, length: 100),
      ];

      expect(
        PmTilesDirectory.deserialize(PmTilesDirectory.serialize(entries)),
        entries,
      );
    });

    test('round-trips a leaf pointer', () {
      const entries = [
        PmTilesEntry(tileId: 0, offset: 0, length: 64, runLength: 0),
      ];
      final decoded = PmTilesDirectory.deserialize(
        PmTilesDirectory.serialize(entries),
      );
      expect(decoded.single.isLeaf, isTrue);
    });

    test('writes a contiguous offset as zero', () {
      // Two entries laid end to end cost less than two at unrelated offsets,
      // because the second offset collapses to a single zero byte.
      const contiguous = [
        PmTilesEntry(tileId: 0, offset: 0, length: 1000),
        PmTilesEntry(tileId: 1, offset: 1000, length: 1000),
      ];
      const scattered = [
        PmTilesEntry(tileId: 0, offset: 0, length: 1000),
        PmTilesEntry(tileId: 1, offset: 500000, length: 1000),
      ];

      expect(
        PmTilesDirectory.serialize(contiguous).length,
        lessThan(PmTilesDirectory.serialize(scattered).length),
      );
    });

    test('round-trips an empty directory', () {
      expect(
        PmTilesDirectory.deserialize(PmTilesDirectory.serialize(const [])),
        isEmpty,
      );
    });
  });

  group('PmTilesWriter', () {
    test('writes an archive the pmtiles package can read', () async {
      final writer = PmTilesWriter()..addZxy(14, 6185, 9404, _tile(1));

      final archive = await _open(writer.build());
      addTearDown(archive.close);

      final id = TileId.fromZxy(14, 6185, 9404);
      expect((await archive.tile(id)).bytes(), _tile(1));
    });

    test('reports the zoom range it was given', () async {
      final writer = PmTilesWriter()
        ..addZxy(10, 100, 200, _tile(1))
        ..addZxy(14, 6185, 9404, _tile(2));

      final header = PmTilesHeader.fromBytes(writer.build());
      expect(header.minZoom, 10);
      expect(header.maxZoom, 14);
    });

    test('round-trips metadata', () async {
      final writer = PmTilesWriter(
        metadata: {
          'name': 'Balneário Camboriú',
          'vector_layers': [
            {'id': 'road', 'fields': <String, Object?>{}},
          ],
        },
      )..addZxy(14, 6185, 9404, _tile(1));

      final archive = await _open(writer.build());
      addTearDown(archive.close);

      final metadata = await archive.metadata as Map<String, Object?>;
      expect(metadata['name'], 'Balneário Camboriú');
      expect(metadata['vector_layers'], hasLength(1));
    });

    test('deduplicates identical tiles that are far apart', () async {
      final writer = PmTilesWriter()
        ..add(TileId.zoomOffset(10) + 0, _tile(7))
        ..add(TileId.zoomOffset(10) + 500, _tile(7));

      // Two addresses, two entries — but only one copy of the bytes.
      expect(writer.addressedTileCount, 2);
      expect(writer.entryCount, 2);
      expect(writer.contentCount, 1);

      final archive = await _open(writer.build());
      addTearDown(archive.close);
      expect(
        (await archive.tile(TileId.zoomOffset(10) + 500)).bytes(),
        _tile(7),
      );
    });

    test(
      'run-length encodes identical adjacent tiles into one entry',
      () async {
        final writer = PmTilesWriter();
        final base = TileId.zoomOffset(10);
        for (var i = 0; i < 50; i++) {
          writer.add(base + i, _tile(7));
        }

        // This is the ocean: fifty addresses, one entry, one blob.
        expect(writer.addressedTileCount, 50);
        expect(writer.entryCount, 1);
        expect(writer.contentCount, 1);

        final archive = await _open(writer.build());
        addTearDown(archive.close);
        // Every id in the run resolves, not just the first.
        expect((await archive.tile(base)).bytes(), _tile(7));
        expect((await archive.tile(base + 49)).bytes(), _tile(7));
      },
    );

    test('keeps distinct adjacent tiles as separate entries', () {
      final writer = PmTilesWriter();
      final base = TileId.zoomOffset(10);
      for (var i = 0; i < 10; i++) {
        writer.add(base + i, _tile(i));
      }

      expect(writer.entryCount, 10);
      expect(writer.contentCount, 10);
    });

    test('ignores empty tiles', () {
      final writer = PmTilesWriter()..add(5, const []);
      expect(writer.entryCount, 0);
      expect(writer.addressedTileCount, 0);
    });

    test('rejects tiles added out of order', () {
      final writer = PmTilesWriter()..add(10, _tile(1));
      expect(
        () => writer.add(9, _tile(2)),
        throwsA(isA<PmTilesFormatException>()),
      );
      expect(
        () => writer.add(10, _tile(2)),
        throwsA(isA<PmTilesFormatException>()),
      );
    });

    test('stores pre-encoded tiles verbatim', () async {
      // The repackaging path: bytes arrive already in the archive's
      // compression and must not be compressed a second time.
      final writer = PmTilesWriter(tileCompression: PmTilesCompression.none)
        ..addEncoded(TileId.zoomOffset(10), _tile(3));

      final archive = await _open(writer.build());
      addTearDown(archive.close);
      expect((await archive.tile(TileId.zoomOffset(10))).bytes(), _tile(3));
    });

    test('spills into leaf directories when the root would overflow', () async {
      // Uncompressed directories overflow the 16 KiB root budget far sooner,
      // which keeps this test quick while exercising the same code path.
      final writer = PmTilesWriter(
        internalCompression: PmTilesCompression.none,
        tileCompression: PmTilesCompression.none,
      );
      final base = TileId.zoomOffset(14);
      const count = 6000;
      for (var i = 0; i < count; i++) {
        writer.add(base + i, _tile(i));
      }
      expect(writer.entryCount, count);

      final bytes = writer.build();
      final header = PmTilesHeader.fromBytes(bytes);

      expect(header.leafDirectoryLength, greaterThan(0));
      expect(
        header.rootDirectoryLength,
        lessThanOrEqualTo(PmTilesHeader.maxRootDirectoryLength),
      );

      final archive = await _open(bytes);
      addTearDown(archive.close);
      // Tiles at both ends and in the middle must resolve through the leaves.
      expect((await archive.tile(base)).bytes(), _tile(0));
      expect(
        (await archive.tile(base + count ~/ 2)).bytes(),
        _tile(count ~/ 2),
      );
      expect((await archive.tile(base + count - 1)).bytes(), _tile(count - 1));
    });

    test('counts addressed tiles, entries and contents independently', () {
      final writer = PmTilesWriter();
      final base = TileId.zoomOffset(10);
      // A run of three identical, then a different one, then the first again.
      writer
        ..add(base, _tile(1))
        ..add(base + 1, _tile(1))
        ..add(base + 2, _tile(1))
        ..add(base + 3, _tile(2))
        ..add(base + 4, _tile(1));

      expect(writer.addressedTileCount, 5);
      // Entries: the run of three, the odd one, the repeat.
      expect(writer.entryCount, 3);
      // Contents: only two distinct blobs were ever stored.
      expect(writer.contentCount, 2);
    });

    test('writes an archive to a file', () async {
      final dir = await Directory.systemTemp.createTemp('gtb_pmtiles_');
      addTearDown(() => dir.delete(recursive: true));

      final path = '${dir.path}/test.pmtiles';
      await (PmTilesWriter()..addZxy(14, 6185, 9404, _tile(1))).writeToFile(
        path,
      );

      final archive = await oracle.PmTilesArchive.from(path);
      addTearDown(archive.close);
      expect(
        (await archive.tile(TileId.fromZxy(14, 6185, 9404))).bytes(),
        _tile(1),
      );
    });
  });
}
