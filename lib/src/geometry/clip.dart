import '../mvt/mvt_tile.dart';

/// An axis-aligned clipping rectangle, in whatever space its coordinates are.
class ClipRect {
  final int minX;
  final int minY;
  final int maxX;
  final int maxY;

  const ClipRect(this.minX, this.minY, this.maxX, this.maxY);

  /// The rectangle for a tile's local grid, widened by [buffer].
  ///
  /// The buffer is what stops lines dying at the tile seam: a renderer needs a
  /// little geometry beyond the edge so that line joins, caps and label
  /// placement look continuous across the join. Discard it and roads visibly
  /// break at every tile boundary.
  factory ClipRect.tile({int extent = 4096, int buffer = 64}) =>
      ClipRect(-buffer, -buffer, extent + buffer, extent + buffer);

  bool contains(MvtPoint p) =>
      p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY;

  /// Whether this rectangle overlaps the box `(x0,y0)-(x1,y1)` at all.
  bool intersectsBox(int x0, int y0, int x1, int y1) =>
      x1 >= minX && x0 <= maxX && y1 >= minY && y0 <= maxY;

  @override
  String toString() => 'ClipRect($minX, $minY, $maxX, $maxY)';
}

/// Clipping of geometry against a tile rectangle.
abstract final class Clip {
  // Cohen–Sutherland region codes.
  static const int _inside = 0;
  static const int _left = 1;
  static const int _right = 2;
  static const int _bottom = 4;
  static const int _top = 8;

  /// Clips a polyline to [rect], returning the pieces that survive.
  ///
  /// A line can leave and re-enter the rectangle, so the result is a *list* of
  /// runs rather than one. Each run has at least two vertices; a line that
  /// merely grazes a corner produces nothing.
  ///
  /// Vertices strictly inside are preserved exactly; only the crossings are
  /// computed, so an unclipped line comes back unchanged.
  static List<List<MvtPoint>> polyline(List<MvtPoint> line, ClipRect rect) {
    if (line.length < 2) return const [];

    final runs = <List<MvtPoint>>[];
    List<MvtPoint>? current;

    for (var i = 0; i + 1 < line.length; i++) {
      final segment = _clipSegment(line[i], line[i + 1], rect);
      if (segment == null) {
        // Wholly outside: whatever run was open ends here.
        current = null;
        continue;
      }

      final (a, b) = segment;
      if (current == null) {
        current = [a, b];
        runs.add(current);
      } else if (a == current.last) {
        // Continues the open run.
        current.add(b);
      } else {
        // Re-entered somewhere else; start a new run.
        current = [a, b];
        runs.add(current);
      }

      // If this segment was cut short at the far end, the line has left the
      // rectangle and the next segment cannot continue this run.
      if (b != line[i + 1]) current = null;
    }

    return [
      for (final run in runs)
        if (run.length >= 2) run,
    ];
  }

  /// Cohen–Sutherland clip of one segment, or null if it misses entirely.
  static (MvtPoint, MvtPoint)? _clipSegment(
    MvtPoint p0,
    MvtPoint p1,
    ClipRect r,
  ) {
    var x0 = p0.x.toDouble(), y0 = p0.y.toDouble();
    var x1 = p1.x.toDouble(), y1 = p1.y.toDouble();
    var code0 = _regionCode(x0, y0, r);
    var code1 = _regionCode(x1, y1, r);

    while (true) {
      if ((code0 | code1) == _inside) {
        return (
          MvtPoint(x0.round(), y0.round()),
          MvtPoint(x1.round(), y1.round()),
        );
      }
      // Both endpoints share an outside region: the segment cannot cross.
      if ((code0 & code1) != 0) return null;

      final outside = code0 != _inside ? code0 : code1;
      double x, y;

      if ((outside & _top) != 0) {
        x = x0 + (x1 - x0) * (r.maxY - y0) / (y1 - y0);
        y = r.maxY.toDouble();
      } else if ((outside & _bottom) != 0) {
        x = x0 + (x1 - x0) * (r.minY - y0) / (y1 - y0);
        y = r.minY.toDouble();
      } else if ((outside & _right) != 0) {
        y = y0 + (y1 - y0) * (r.maxX - x0) / (x1 - x0);
        x = r.maxX.toDouble();
      } else {
        y = y0 + (y1 - y0) * (r.minX - x0) / (x1 - x0);
        x = r.minX.toDouble();
      }

      if (outside == code0) {
        x0 = x;
        y0 = y;
        code0 = _regionCode(x0, y0, r);
      } else {
        x1 = x;
        y1 = y;
        code1 = _regionCode(x1, y1, r);
      }
    }
  }

  static int _regionCode(double x, double y, ClipRect r) {
    var code = _inside;
    if (x < r.minX) {
      code |= _left;
    } else if (x > r.maxX) {
      code |= _right;
    }
    if (y < r.minY) {
      code |= _bottom;
    } else if (y > r.maxY) {
      code |= _top;
    }
    return code;
  }

  /// Clips a polygon ring to [rect] by the Sutherland–Hodgman algorithm.
  ///
  /// Unlike a polyline, a ring must stay closed, so the rectangle's own corners
  /// are introduced where the ring leaves and re-enters. The result is a single
  /// ring or nothing.
  ///
  /// The algorithm assumes a convex clip region — true of a rectangle — and can
  /// leave degenerate spurs on strongly concave input, which is acceptable for
  /// tile rendering and is why the result is deduped.
  static List<MvtPoint> ring(List<MvtPoint> input, ClipRect rect) {
    if (input.length < 3) return const [];

    var output = input;
    for (final edge in _Edge.values) {
      if (output.isEmpty) return const [];
      output = _clipRingToEdge(output, rect, edge);
    }

    if (output.length < 3) return const [];
    // Drop a repeated closing vertex; the encoder adds ClosePath itself.
    if (output.first == output.last) {
      output = output.sublist(0, output.length - 1);
    }
    return output.length < 3 ? const [] : output;
  }

  static List<MvtPoint> _clipRingToEdge(
    List<MvtPoint> ring,
    ClipRect r,
    _Edge edge,
  ) {
    final out = <MvtPoint>[];
    for (var i = 0; i < ring.length; i++) {
      final current = ring[i];
      final previous = ring[(i - 1 + ring.length) % ring.length];
      final currentIn = _insideEdge(current, r, edge);
      final previousIn = _insideEdge(previous, r, edge);

      if (currentIn) {
        if (!previousIn) out.add(_edgeIntersection(previous, current, r, edge));
        out.add(current);
      } else if (previousIn) {
        out.add(_edgeIntersection(previous, current, r, edge));
      }
    }
    return out;
  }

  static bool _insideEdge(MvtPoint p, ClipRect r, _Edge edge) => switch (edge) {
    _Edge.left => p.x >= r.minX,
    _Edge.right => p.x <= r.maxX,
    _Edge.bottom => p.y >= r.minY,
    _Edge.top => p.y <= r.maxY,
  };

  static MvtPoint _edgeIntersection(
    MvtPoint a,
    MvtPoint b,
    ClipRect r,
    _Edge edge,
  ) {
    final ax = a.x.toDouble(), ay = a.y.toDouble();
    final bx = b.x.toDouble(), by = b.y.toDouble();

    return switch (edge) {
      _Edge.left => MvtPoint(
        r.minX,
        (ay + (by - ay) * (r.minX - ax) / (bx - ax)).round(),
      ),
      _Edge.right => MvtPoint(
        r.maxX,
        (ay + (by - ay) * (r.maxX - ax) / (bx - ax)).round(),
      ),
      _Edge.bottom => MvtPoint(
        (ax + (bx - ax) * (r.minY - ay) / (by - ay)).round(),
        r.minY,
      ),
      _Edge.top => MvtPoint(
        (ax + (bx - ax) * (r.maxY - ay) / (by - ay)).round(),
        r.maxY,
      ),
    };
  }
}

enum _Edge { left, right, bottom, top }
