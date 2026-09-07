import 'dart:math' as math;

import '../mvt/mvt_tile.dart';
import '../pmtiles/tile_id.dart';

/// Web Mercator (EPSG:3857) projection, in the tile-pyramid form every slippy
/// map uses.
///
/// The world is a square: longitude maps linearly to `x` in `0..1`, latitude
/// maps through the Mercator function to `y` in `0..1` with `y` increasing
/// *southward*. Multiplying by `2^z` gives fractional tile coordinates at that
/// zoom, and the fractional part positions a point inside its tile.
///
/// Latitude is clamped to ±[maxLatitude]: the projection sends the poles to
/// infinity, so the whole slippy-map world is the square between those two
/// parallels. A point outside is not an error — it is simply off the map, and
/// clamping keeps it at the edge rather than producing an infinite coordinate.
abstract final class Mercator {
  /// The latitude at which the Web Mercator square closes, in degrees.
  ///
  /// `atan(sinh(pi))` — the value that makes the projected world exactly
  /// square, and the reason slippy maps stop short of the poles.
  static const double maxLatitude = 85.05112877980659;

  /// Clamps [lat] into the projectable range.
  static double clampLatitude(double lat) => lat < -maxLatitude
      ? -maxLatitude
      : (lat > maxLatitude ? maxLatitude : lat);

  /// Longitude to `x` in `0..1`, west to east.
  static double xOf(double lon) => (lon + 180.0) / 360.0;

  /// Latitude to `y` in `0..1`, north to south.
  static double yOf(double lat) {
    final rad = clampLatitude(lat) * math.pi / 180.0;
    return (1.0 - math.log(math.tan(rad) + 1.0 / math.cos(rad)) / math.pi) /
        2.0;
  }

  /// `x` in `0..1` back to longitude.
  static double lonOfX(double x) => x * 360.0 - 180.0;

  /// `y` in `0..1` back to latitude.
  static double latOfY(double y) {
    final n = math.pi * (1.0 - 2.0 * y);
    return 180.0 / math.pi * math.atan(_sinh(n));
  }

  /// Fractional tile coordinates of [lon]/[lat] at [zoom].
  ///
  /// The integer parts name the tile; the fractional parts locate the point
  /// within it.
  static (double, double) tileOf(double lon, double lat, int zoom) {
    final scale = (1 << zoom).toDouble();
    return (xOf(lon) * scale, yOf(lat) * scale);
  }

  /// The tile containing [lon]/[lat] at [zoom].
  static Zxy tileAt(double lon, double lat, int zoom) {
    final scale = 1 << zoom;
    final (fx, fy) = tileOf(lon, lat, zoom);
    // A point exactly on the eastern or southern edge of the world would
    // otherwise index one tile past the grid.
    final x = fx.floor().clamp(0, scale - 1);
    final y = fy.floor().clamp(0, scale - 1);
    return Zxy(zoom, x, y);
  }

  /// Projects [lon]/[lat] into tile-local integer coordinates inside [tile].
  ///
  /// The result is in the `0 .. extent` grid an [MvtLayer] uses, with the
  /// origin at the tile's top-left and Y pointing down. Values outside that
  /// range are returned as-is rather than clamped: geometry that leaves the
  /// tile belongs in its buffer, and only the clipper decides how far out to
  /// keep.
  static MvtPoint project(
    double lon,
    double lat,
    Zxy tile, {
    int extent = 4096,
  }) {
    final (fx, fy) = tileOf(lon, lat, tile.z);
    return MvtPoint(
      ((fx - tile.x) * extent).round(),
      ((fy - tile.y) * extent).round(),
    );
  }

  /// Projects [lon]/[lat] into **world** coordinates at [zoom]: tile-extent
  /// units measured from the top-left of the whole map.
  ///
  /// This is the space a pipeline should do its work in. A way projected once
  /// per zoom can then be simplified once, and every tile that touches it is a
  /// subtraction away — whereas projecting per tile repeats the trigonometry
  /// for every tile the way crosses.
  ///
  /// The values stay well inside 64-bit integers: at zoom 15 with extent 4096
  /// the world is 134,217,728 units across.
  static MvtPoint world(double lon, double lat, int zoom, {int extent = 4096}) {
    final scale = (1 << zoom).toDouble() * extent;
    return MvtPoint((xOf(lon) * scale).round(), (yOf(lat) * scale).round());
  }

  /// Translates a world coordinate into [tile]'s local grid.
  static MvtPoint toLocal(MvtPoint world, Zxy tile, {int extent = 4096}) =>
      MvtPoint(world.x - tile.x * extent, world.y - tile.y * extent);

  /// The range of tiles at [zoom] spanned by world x/y bounds.
  ///
  /// Returned as `(minTileX, minTileY, maxTileX, maxTileY)`, clamped to the
  /// grid. Feeding it a feature's bounding box gives the candidate tiles to
  /// clip that feature against.
  static (int, int, int, int) tileRangeOfWorld(
    int minX,
    int minY,
    int maxX,
    int maxY,
    int zoom, {
    int extent = 4096,
  }) {
    final last = (1 << zoom) - 1;
    return (
      (minX / extent).floor().clamp(0, last),
      (minY / extent).floor().clamp(0, last),
      (maxX / extent).floor().clamp(0, last),
      (maxY / extent).floor().clamp(0, last),
    );
  }

  /// The geographic bounds of [tile], as `(minLon, minLat, maxLon, maxLat)`.
  static (double, double, double, double) boundsOf(Zxy tile) {
    final scale = (1 << tile.z).toDouble();
    final west = lonOfX(tile.x / scale);
    final east = lonOfX((tile.x + 1) / scale);
    // y grows southward, so the tile's top edge is its *maximum* latitude.
    final north = latOfY(tile.y / scale);
    final south = latOfY((tile.y + 1) / scale);
    return (west, south, east, north);
  }

  /// Every tile at [zoom] covering the given bounds, in tile-id order.
  ///
  /// Ordering matters: a PMTiles archive must be written along the Hilbert
  /// curve, which is not row-major, so callers that iterate `x` then `y` and
  /// write as they go will be rejected by the writer.
  static List<Zxy> coverage(
    double minLon,
    double minLat,
    double maxLon,
    double maxLat,
    int zoom,
  ) {
    final topLeft = tileAt(minLon, maxLat, zoom);
    final bottomRight = tileAt(maxLon, minLat, zoom);

    final tiles = <Zxy>[];
    for (var x = topLeft.x; x <= bottomRight.x; x++) {
      for (var y = topLeft.y; y <= bottomRight.y; y++) {
        tiles.add(Zxy(zoom, x, y));
      }
    }
    tiles.sort((a, b) => TileId.of(a).compareTo(TileId.of(b)));
    return tiles;
  }

  static double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2.0;
}
