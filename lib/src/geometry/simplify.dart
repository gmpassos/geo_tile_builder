import '../mvt/mvt_tile.dart';

/// Line generalisation.
///
/// A road digitised for survey accuracy carries far more vertices than any
/// screen can show. Dropping the ones that make no visible difference is the
/// cheapest size reduction available, and unlike dropping whole features it
/// costs nothing a viewer can perceive.
abstract final class Simplify {
  /// Ramer–Douglas–Peucker simplification of [points].
  ///
  /// Keeps the first and last vertex and, recursively, whichever vertex lies
  /// furthest from the chord between them — stopping once that distance falls
  /// below [tolerance]. The result therefore never wanders further than
  /// `tolerance` from the original line, which is what makes the tolerance
  /// meaningful in tile-extent units: set it under a pixel and the change is
  /// invisible by construction.
  ///
  /// A [tolerance] of `0` or fewer than three points returns [points]
  /// unchanged.
  static List<MvtPoint> douglasPeucker(List<MvtPoint> points, int tolerance) {
    if (tolerance <= 0 || points.length < 3) return points;

    final keep = List<bool>.filled(points.length, false);
    keep[0] = true;
    keep[points.length - 1] = true;

    // Compare squared distances so the inner loop stays in integers.
    _simplifySection(points, 0, points.length - 1, tolerance * tolerance, keep);

    final out = <MvtPoint>[];
    for (var i = 0; i < points.length; i++) {
      if (keep[i]) out.add(points[i]);
    }
    return out;
  }

  /// Marks the vertices worth keeping between [first] and [last].
  ///
  /// Iterative rather than recursive: a single OSM way can carry tens of
  /// thousands of vertices, and a pathological one would otherwise blow the
  /// stack.
  static void _simplifySection(
    List<MvtPoint> points,
    int first,
    int last,
    int toleranceSquared,
    List<bool> keep,
  ) {
    final stack = <(int, int)>[(first, last)];

    while (stack.isNotEmpty) {
      final (from, to) = stack.removeLast();
      if (to <= from + 1) continue;

      var maxDistance = -1.0;
      var maxIndex = from;

      for (var i = from + 1; i < to; i++) {
        final d = _squaredDistanceToSegment(
          points[i],
          points[from],
          points[to],
        );
        if (d > maxDistance) {
          maxDistance = d;
          maxIndex = i;
        }
      }

      if (maxDistance > toleranceSquared) {
        keep[maxIndex] = true;
        stack
          ..add((from, maxIndex))
          ..add((maxIndex, to));
      }
    }
  }

  /// Squared perpendicular distance from [p] to the segment [a]–[b].
  ///
  /// Degenerate segments (a == b) fall back to the squared distance to the
  /// point, which keeps a duplicated vertex from being treated as infinitely
  /// far away.
  static double _squaredDistanceToSegment(MvtPoint p, MvtPoint a, MvtPoint b) {
    final dx = (b.x - a.x).toDouble();
    final dy = (b.y - a.y).toDouble();

    if (dx == 0 && dy == 0) {
      final px = (p.x - a.x).toDouble();
      final py = (p.y - a.y).toDouble();
      return px * px + py * py;
    }

    // Projection parameter of p onto the infinite line, clamped to the segment.
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy);
    if (t < 0) {
      t = 0;
    } else if (t > 1) {
      t = 1;
    }

    final projX = a.x + t * dx;
    final projY = a.y + t * dy;
    final ex = p.x - projX;
    final ey = p.y - projY;
    return ex * ex + ey * ey;
  }

  /// Removes consecutive duplicate vertices.
  ///
  /// Quantising to a tile's integer grid routinely collapses neighbouring
  /// vertices onto the same point; the resulting zero-length segments encode
  /// bytes that draw nothing.
  static List<MvtPoint> dedupe(List<MvtPoint> points) {
    if (points.length < 2) return points;
    final out = <MvtPoint>[points.first];
    for (var i = 1; i < points.length; i++) {
      if (points[i] != out.last) out.add(points[i]);
    }
    return out;
  }
}
