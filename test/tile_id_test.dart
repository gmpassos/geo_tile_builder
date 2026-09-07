import 'dart:math';

import 'package:geo_tile_builder/geo_tile_builder.dart';
import 'package:test/test.dart';

void main() {
  group('TileId', () {
    test('accumulates 4^z tiles per zoom level', () {
      expect(TileId.zoomOffset(0), 0);
      expect(TileId.zoomOffset(1), 1); // z0 contributed 1 tile
      expect(TileId.zoomOffset(2), 5); // + 4 tiles at z1
      expect(TileId.zoomOffset(3), 21); // + 16 tiles at z2
      expect(TileId.zoomOffset(4), 85);
    });

    test('places the single z0 tile at id 0', () {
      expect(TileId.fromZxy(0, 0, 0), 0);
    });

    test('orders z1 along the Hilbert curve, not row by row', () {
      // The curve visits (0,0) -> (0,1) -> (1,1) -> (1,0): down, across, up.
      // Row-major order would have given (1,0) id 2 rather than 4.
      expect(TileId.fromZxy(1, 0, 0), 1);
      expect(TileId.fromZxy(1, 0, 1), 2);
      expect(TileId.fromZxy(1, 1, 1), 3);
      expect(TileId.fromZxy(1, 1, 0), 4);
    });

    test('starts z2 immediately after z1', () {
      expect(TileId.fromZxy(2, 0, 0), 5);
    });

    test('assigns every tile in a zoom a distinct consecutive id', () {
      for (final z in [1, 2, 3, 4]) {
        final n = 1 << z;
        final ids = <int>{};
        for (var x = 0; x < n; x++) {
          for (var y = 0; y < n; y++) {
            ids.add(TileId.fromZxy(z, x, y));
          }
        }
        expect(ids, hasLength(n * n));
        expect(ids.reduce(min), TileId.zoomOffset(z));
        expect(ids.reduce(max), TileId.zoomOffset(z) + n * n - 1);
      }
    });

    test('keeps consecutive ids spatially adjacent', () {
      // The whole point of Hilbert ordering: a step along the curve is a step
      // on the map, which is what keeps viewport reads contiguous.
      const z = 5;
      final n = 1 << z;
      for (var d = 0; d < n * n - 1; d++) {
        final a = TileId.toZxy(TileId.zoomOffset(z) + d);
        final b = TileId.toZxy(TileId.zoomOffset(z) + d + 1);
        expect((a.x - b.x).abs() + (a.y - b.y).abs(), 1, reason: 'step $d');
      }
    });

    test('round-trips z/x/y through the id space', () {
      final rnd = Random(20260907);
      for (var z = 0; z <= 14; z++) {
        final n = 1 << z;
        for (var i = 0; i < 40; i++) {
          final x = rnd.nextInt(n);
          final y = rnd.nextInt(n);
          expect(TileId.toZxy(TileId.fromZxy(z, x, y)), Zxy(z, x, y));
        }
      }
    });

    test('round-trips a deep zoom', () {
      // Balneário Camboriú at z16, roughly.
      const zxy = Zxy(16, 24743, 37619);
      expect(TileId.toZxy(TileId.of(zxy)), zxy);
    });

    test('rejects coordinates outside the grid', () {
      expect(() => TileId.fromZxy(1, 2, 0), throwsA(isA<TileIdException>()));
      expect(() => TileId.fromZxy(0, 0, 1), throwsA(isA<TileIdException>()));
      expect(() => TileId.fromZxy(2, -1, 0), throwsA(isA<TileIdException>()));
    });

    test('rejects an out-of-range zoom or a negative id', () {
      expect(() => TileId.fromZxy(-1, 0, 0), throwsA(isA<TileIdException>()));
      expect(() => TileId.fromZxy(32, 0, 0), throwsA(isA<TileIdException>()));
      expect(() => TileId.toZxy(-1), throwsA(isA<TileIdException>()));
    });
  });
}
