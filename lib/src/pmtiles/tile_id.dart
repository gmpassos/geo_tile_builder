/// Thrown when a tile coordinate is outside its zoom level's grid.
class TileIdException implements Exception {
  final String message;

  const TileIdException(this.message);

  @override
  String toString() => 'TileIdException: $message';
}

/// A `z/x/y` tile address in the standard Web Mercator scheme.
///
/// `x` runs west to east and `y` north to south, both in `0 .. 2^z - 1`.
class Zxy {
  final int z;
  final int x;
  final int y;

  const Zxy(this.z, this.x, this.y);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Zxy && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => '$z/$x/$y';
}

/// Conversion between `z/x/y` addresses and PMTiles tile ids.
///
/// PMTiles numbers tiles along a **Hilbert curve**, zoom level by zoom level:
/// id 0 is the single tile at z0, ids 1–4 are z1, ids 5–20 are z2, and so on.
/// The Hilbert ordering is what makes the format efficient — neighbouring tiles
/// on the curve are neighbours on the map, so a viewport's tiles land in a few
/// contiguous byte ranges and a reader fetches them with very few HTTP range
/// requests. It is also why an archive must be written in id order.
abstract final class TileId {
  /// Highest zoom the 64-bit id space can address.
  static const int maxZoom = 31;

  /// Number of tile ids occupied by every zoom level below [z].
  ///
  /// The levels form a geometric series — `1 + 4 + 16 + …` — which sums to
  /// `(4^z - 1) / 3`.
  static int zoomOffset(int z) {
    _checkZoom(z);
    return ((1 << (2 * z)) - 1) ~/ 3;
  }

  /// Converts a `z/x/y` address to its tile id.
  static int fromZxy(int z, int x, int y) {
    _checkZoom(z);
    final n = 1 << z;
    if (x < 0 || y < 0 || x >= n || y >= n) {
      throw TileIdException('tile $z/$x/$y is outside the ${n}x$n grid at z$z');
    }

    var rx = 0, ry = 0, d = 0;
    var tx = x, ty = y;
    for (var s = n >> 1; s > 0; s >>= 1) {
      rx = (tx & s) > 0 ? 1 : 0;
      ry = (ty & s) > 0 ? 1 : 0;
      d += s * s * ((3 * rx) ^ ry);
      // Rotate the quadrant so the curve stays continuous across it.
      if (ry == 0) {
        if (rx == 1) {
          tx = s - 1 - tx;
          ty = s - 1 - ty;
        }
        final swap = tx;
        tx = ty;
        ty = swap;
      }
    }

    return zoomOffset(z) + d;
  }

  /// Converts [zxy] to its tile id.
  static int of(Zxy zxy) => fromZxy(zxy.z, zxy.x, zxy.y);

  /// Converts a tile id back to its `z/x/y` address.
  static Zxy toZxy(int id) {
    if (id < 0) {
      throw TileIdException('tile id $id is negative');
    }

    var z = 0;
    var acc = 0;
    while (true) {
      final count = 1 << (2 * z); // 4^z tiles at this zoom
      if (id < acc + count) break;
      acc += count;
      z++;
      if (z > maxZoom) {
        throw TileIdException('tile id $id is beyond zoom $maxZoom');
      }
    }

    var d = id - acc;
    final n = 1 << z;
    var tx = 0, ty = 0;
    for (var s = 1; s < n; s <<= 1) {
      final rx = 1 & (d >> 1);
      final ry = 1 & (d ^ rx);
      if (ry == 0) {
        if (rx == 1) {
          tx = s - 1 - tx;
          ty = s - 1 - ty;
        }
        final swap = tx;
        tx = ty;
        ty = swap;
      }
      tx += s * rx;
      ty += s * ry;
      d >>= 2;
    }

    return Zxy(z, tx, ty);
  }

  static void _checkZoom(int z) {
    if (z < 0 || z > maxZoom) {
      throw TileIdException('zoom $z is outside 0..$maxZoom');
    }
  }
}
