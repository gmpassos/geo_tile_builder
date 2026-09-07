import 'mvt_tile.dart';

/// Thrown when geometry cannot be expressed in the vector tile wire format.
class MvtGeometryException implements Exception {
  final String message;

  const MvtGeometryException(this.message);

  @override
  String toString() => 'MvtGeometryException: $message';
}

/// Encodes feature geometry into the vector tile command stream.
///
/// The stream is a flat list of integers mixing *command* and *parameter*
/// integers. A command integer packs an id and a repeat count
/// (`(id & 0x7) | (count << 3)`); each repeat then consumes that command's
/// parameters, which are zig-zag encoded **deltas from a cursor** that starts
/// at the tile origin and is left wherever the previous command finished.
/// Delta encoding is why coordinates stay in one or two bytes each.
abstract final class MvtGeometryEncoder {
  /// `MoveTo`: sets the cursor and starts a new point run. Takes 2 parameters.
  static const int commandMoveTo = 1;

  /// `LineTo`: extends the current run. Takes 2 parameters.
  static const int commandLineTo = 2;

  /// `ClosePath`: closes the current ring. Takes no parameters.
  static const int commandClosePath = 7;

  /// The largest coordinate delta the parameter encoding can carry.
  static const int maxParameter = 2147483647; // 2^31 - 1

  /// Packs a command id and repeat count into a command integer.
  static int command(int id, int count) => (id & 0x7) | (count << 3);

  /// Zig-zag encodes a coordinate delta.
  static int parameter(int delta) {
    if (delta > maxParameter || delta < -maxParameter) {
      throw MvtGeometryException(
        'coordinate delta $delta exceeds the +/-(2^31 - 1) parameter range',
      );
    }
    return (delta << 1) ^ (delta >> 63);
  }

  /// The signed area of [ring], doubled, using the surveyor's formula.
  ///
  /// In tile coordinates Y increases *downward*, and the spec defines an
  /// exterior ring as one with **positive** area and an interior ring (a hole)
  /// as one with negative area. Renderers rely on this to tell holes from
  /// separate polygons, so getting the winding wrong makes holes vanish or
  /// swallow their parent.
  ///
  /// Returned doubled to keep the arithmetic exact in integers; only the sign
  /// and relative magnitude matter to callers.
  static int doubledSignedArea(List<MvtPoint> ring) {
    var area = 0;
    for (var i = 0; i < ring.length; i++) {
      final a = ring[i];
      final b = ring[(i + 1) % ring.length];
      area += (a.x * b.y) - (b.x * a.y);
    }
    return area;
  }

  /// Encodes [feature]'s geometry as a command stream.
  ///
  /// The caller is responsible for ring winding (see [doubledSignedArea]); the
  /// encoder preserves the order and direction it is given rather than
  /// silently rewriting geometry.
  static List<int> encode(MvtFeature feature) {
    final parts = feature.parts;
    if (parts.isEmpty) return const [];

    return switch (feature.type) {
      MvtGeomType.point => _encodePoints(parts),
      MvtGeomType.lineString => _encodeLines(parts, close: false),
      MvtGeomType.polygon => _encodeLines(_unclosed(parts), close: true),
      MvtGeomType.unknown => throw const MvtGeometryException(
        'cannot encode geometry of unknown type',
      ),
    };
  }

  /// Points are a single `MoveTo` whose count is the number of points, so a
  /// multipoint costs one command for the whole set.
  static List<int> _encodePoints(List<List<MvtPoint>> parts) {
    final points = [for (final part in parts) ...part];
    if (points.isEmpty) return const [];

    final out = <int>[command(commandMoveTo, points.length)];
    var cx = 0, cy = 0;
    for (final p in points) {
      out.add(parameter(p.x - cx));
      out.add(parameter(p.y - cy));
      cx = p.x;
      cy = p.y;
    }
    return out;
  }

  /// Lines and rings share an encoding: `MoveTo(1)` to the first vertex, then
  /// one `LineTo` covering every remaining vertex, plus `ClosePath` for rings.
  static List<int> _encodeLines(
    List<List<MvtPoint>> parts, {
    required bool close,
  }) {
    final out = <int>[];
    var cx = 0, cy = 0;

    for (final part in parts) {
      // A line needs two distinct vertices and a ring needs three; anything
      // less cannot render, so drop it rather than emit a degenerate command.
      if (part.length < (close ? 3 : 2)) continue;

      final first = part.first;
      out.add(command(commandMoveTo, 1));
      out.add(parameter(first.x - cx));
      out.add(parameter(first.y - cy));
      cx = first.x;
      cy = first.y;

      out.add(command(commandLineTo, part.length - 1));
      for (var i = 1; i < part.length; i++) {
        final p = part[i];
        out.add(parameter(p.x - cx));
        out.add(parameter(p.y - cy));
        cx = p.x;
        cy = p.y;
      }

      if (close) out.add(command(commandClosePath, 1));
    }

    return out;
  }

  /// Drops a repeated closing vertex from each ring.
  ///
  /// Most geometry pipelines represent a ring with its first point repeated at
  /// the end; the tile format instead closes rings with `ClosePath`, so the
  /// duplicate would add a zero-length segment.
  static List<List<MvtPoint>> _unclosed(List<List<MvtPoint>> rings) => [
    for (final ring in rings)
      if (ring.length > 1 && ring.first == ring.last)
        ring.sublist(0, ring.length - 1)
      else
        ring,
  ];
}
