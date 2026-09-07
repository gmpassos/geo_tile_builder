import 'package:geo_tile_builder/geo_tile_builder.dart';
import 'package:test/test.dart';

/// Balneário Camboriú, the app's home city.
const _lon = -48.6353;
const _lat = -26.9906;

void main() {
  group('Mercator', () {
    test('maps the world corners to the unit square', () {
      expect(Mercator.xOf(-180), closeTo(0, 1e-12));
      expect(Mercator.xOf(180), closeTo(1, 1e-12));
      expect(Mercator.yOf(Mercator.maxLatitude), closeTo(0, 1e-9));
      expect(Mercator.yOf(-Mercator.maxLatitude), closeTo(1, 1e-9));
    });

    test('puts the origin at the centre', () {
      expect(Mercator.xOf(0), closeTo(0.5, 1e-12));
      expect(Mercator.yOf(0), closeTo(0.5, 1e-12));
    });

    test('runs y southward', () {
      // Northern latitudes are nearer the top of the world square.
      expect(Mercator.yOf(45), lessThan(Mercator.yOf(0)));
      expect(Mercator.yOf(0), lessThan(Mercator.yOf(-45)));
    });

    test('clamps beyond the projectable range instead of diverging', () {
      expect(Mercator.yOf(90), closeTo(Mercator.yOf(Mercator.maxLatitude), 0));
      expect(
        Mercator.yOf(-90),
        closeTo(Mercator.yOf(-Mercator.maxLatitude), 0),
      );
      expect(Mercator.yOf(90).isFinite, isTrue);
    });

    test('round-trips lon/lat through the unit square', () {
      for (final lon in [-179.9, -48.6353, 0.0, 13.4, 179.9]) {
        expect(Mercator.lonOfX(Mercator.xOf(lon)), closeTo(lon, 1e-9));
      }
      for (final lat in [-84.0, -26.9906, 0.0, 51.5, 84.0]) {
        expect(Mercator.latOfY(Mercator.yOf(lat)), closeTo(lat, 1e-9));
      }
    });

    test('agrees with the known slippy tile for a real place', () {
      // Cross-checked against the standard slippy-map formula: Balneário
      // Camboriú sits in 14/5978/9468.
      final tile = Mercator.tileAt(_lon, _lat, 14);
      expect(tile.z, 14);
      expect(tile.x, 5978);
      expect(tile.y, 9468);
    });

    test('has one tile at zoom 0 holding everything', () {
      expect(Mercator.tileAt(_lon, _lat, 0), const Zxy(0, 0, 0));
      expect(Mercator.tileAt(179.0, 84.0, 0), const Zxy(0, 0, 0));
    });

    test('keeps edge points inside the grid', () {
      final scale = (1 << 4) - 1;
      expect(Mercator.tileAt(180, 0, 4).x, scale);
      expect(Mercator.tileAt(0, -Mercator.maxLatitude, 4).y, scale);
    });

    test('projects a point into its own tile', () {
      final tile = Mercator.tileAt(_lon, _lat, 14);
      final p = Mercator.project(_lon, _lat, tile);

      // Inside the 0..4096 grid, since the point is in this very tile.
      expect(p.x, inInclusiveRange(0, 4096));
      expect(p.y, inInclusiveRange(0, 4096));
    });

    test("projects a neighbour's point outside the extent", () {
      // Geometry crossing into the next tile must come out beyond the extent,
      // not wrapped or clamped — the clipper decides what to keep.
      final tile = Mercator.tileAt(_lon, _lat, 14);
      final east = Mercator.boundsOf(tile).$3;
      final p = Mercator.project(east + 0.01, _lat, tile);
      expect(p.x, greaterThan(4096));
    });

    test('honours a custom extent', () {
      final tile = Mercator.tileAt(_lon, _lat, 14);
      final small = Mercator.project(_lon, _lat, tile, extent: 256);
      expect(small.x, inInclusiveRange(0, 256));
    });

    test('bounds of a tile contain its own centre', () {
      final tile = Mercator.tileAt(_lon, _lat, 14);
      final (west, south, east, north) = Mercator.boundsOf(tile);

      expect(west, lessThan(_lon));
      expect(east, greaterThan(_lon));
      expect(south, lessThan(_lat));
      expect(north, greaterThan(_lat));
      // North is the tile's top edge, which is the larger latitude.
      expect(north, greaterThan(south));
    });

    test('zoom 0 bounds span the whole projectable world', () {
      final (west, south, east, north) = Mercator.boundsOf(const Zxy(0, 0, 0));
      expect(west, closeTo(-180, 1e-9));
      expect(east, closeTo(180, 1e-9));
      expect(north, closeTo(Mercator.maxLatitude, 1e-9));
      expect(south, closeTo(-Mercator.maxLatitude, 1e-9));
    });

    test('covers a bounding box completely', () {
      const minLon = -48.72, minLat = -27.05, maxLon = -48.55, maxLat = -26.94;
      final tiles = Mercator.coverage(minLon, minLat, maxLon, maxLat, 14);

      expect(tiles, isNotEmpty);
      // Both corners of the box must be in the covering set.
      expect(tiles, contains(Mercator.tileAt(minLon, maxLat, 14)));
      expect(tiles, contains(Mercator.tileAt(maxLon, minLat, 14)));
    });

    test('returns coverage in tile-id order, not row-major', () {
      final tiles = Mercator.coverage(-48.72, -27.05, -48.55, -26.94, 14);
      final ids = [for (final t in tiles) TileId.of(t)];

      // The archive writer rejects anything else.
      final sorted = [...ids]..sort();
      expect(ids, sorted);
      // And Hilbert order genuinely differs from iterating x then y.
      final rowMajor = [
        for (final t
            in ([...tiles]..sort(
              (a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y),
            )))
          TileId.of(t),
      ];
      expect(ids, isNot(rowMajor));
    });

    test('covers a single tile when the box is inside one', () {
      final tile = Mercator.tileAt(_lon, _lat, 10);
      final (west, south, east, north) = Mercator.boundsOf(tile);
      final inset = [
        (west + east) / 2 - 1e-6,
        (south + north) / 2 - 1e-6,
        (west + east) / 2 + 1e-6,
        (south + north) / 2 + 1e-6,
      ];
      expect(Mercator.coverage(inset[0], inset[1], inset[2], inset[3], 10), [
        tile,
      ]);
    });
  });
}
