import '../mvt/mvt_geometry.dart';
import '../mvt/mvt_tile.dart';

/// Assembles OpenStreetMap multipolygon members into closed rings.
///
/// A multipolygon relation does not contain rings. It contains *way fragments*,
/// in no particular order and no particular direction, which happen to join end
/// to end into rings — a lake's shoreline is routinely a dozen ways, some drawn
/// clockwise and some anticlockwise, listed in whatever order the last editor
/// left them. Assembling them is the step that hand-rolled tilers get wrong, and
/// getting it wrong shows: holes vanish, or swallow the polygon around them.
///
/// This works in node-id space, before any projection, because joining is
/// topological — two fragments meet when they *share an endpoint node*, not when
/// their coordinates happen to be close.
abstract final class RingBuilder {
  /// Joins [fragments] into closed rings.
  ///
  /// Each fragment is an ordered list of node ids. A fragment may need
  /// reversing to join, and several may chain before a ring closes. Fragments
  /// that cannot be closed are dropped: an unclosed ring is not an area, and
  /// real extracts contain them routinely because a way ran past the extract's
  /// own boundary.
  ///
  /// Returned rings are closed implicitly — the first node is *not* repeated at
  /// the end, matching what [MvtFeature] expects.
  static List<List<int>> assemble(List<List<int>> fragments) {
    // Index fragments by both endpoints so a join is a lookup, not a scan.
    // Without this, a relation with hundreds of members is quadratic.
    final byEndpoint = <int, List<int>>{};
    final used = List<bool>.filled(fragments.length, false);

    for (var i = 0; i < fragments.length; i++) {
      final f = fragments[i];
      if (f.length < 2) {
        used[i] = true; // nothing to join
        continue;
      }
      (byEndpoint[f.first] ??= []).add(i);
      (byEndpoint[f.last] ??= []).add(i);
    }

    final rings = <List<int>>[];

    for (var i = 0; i < fragments.length; i++) {
      if (used[i]) continue;

      final ring = <int>[...fragments[i]];
      used[i] = true;

      // Walk forward from the open end until the ring closes or nothing fits.
      while (ring.first != ring.last) {
        final next = _findJoin(byEndpoint, used, fragments, ring.last);
        if (next == null) break;

        final (index, reversed) = next;
        used[index] = true;
        final piece = reversed
            ? fragments[index].reversed.toList()
            : fragments[index];
        // Skip the shared node so it is not duplicated mid-ring.
        ring.addAll(piece.skip(1));
      }

      // Closed rings only, and a closed ring needs three distinct nodes.
      if (ring.first == ring.last && ring.length >= 4) {
        rings.add(ring.sublist(0, ring.length - 1));
      }
    }

    return rings;
  }

  /// Finds an unused fragment with an endpoint at [node].
  ///
  /// Returns its index and whether it must be reversed to continue the ring.
  static (int, bool)? _findJoin(
    Map<int, List<int>> byEndpoint,
    List<bool> used,
    List<List<int>> fragments,
    int node,
  ) {
    for (final index in byEndpoint[node] ?? const <int>[]) {
      if (used[index]) continue;
      final fragment = fragments[index];
      if (fragment.first == node) return (index, false);
      if (fragment.last == node) return (index, true);
    }
    return null;
  }

  /// Forces [ring] to wind so that its area has the requested sign.
  ///
  /// The vector tile format distinguishes an exterior ring from a hole purely
  /// by winding: exterior rings have positive area in tile coordinates (where Y
  /// points down), holes negative. Source data respects no such convention, so
  /// the winding has to be imposed rather than trusted.
  static List<MvtPoint> orient(List<MvtPoint> ring, {required bool exterior}) {
    if (ring.length < 3) return ring;
    final area = MvtGeometryEncoder.doubledSignedArea(ring);
    final isExterior = area > 0;
    if (isExterior == exterior) return ring;
    return ring.reversed.toList();
  }

  /// Whether [point] lies inside [ring], by the even–odd ray rule.
  ///
  /// Used to decide which exterior ring a hole belongs to. A relation may carry
  /// several separate islands, each with its own holes, and attaching a hole to
  /// the wrong island cuts a bite out of the wrong shape.
  static bool containsPoint(List<MvtPoint> ring, MvtPoint point) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final a = ring[i];
      final b = ring[j];
      // Does the horizontal ray at point.y cross this edge?
      if ((a.y > point.y) != (b.y > point.y)) {
        final t = (point.y - a.y) / (b.y - a.y);
        if (point.x < a.x + t * (b.x - a.x)) inside = !inside;
      }
    }
    return inside;
  }

  /// Orders exterior rings and their holes into vector-tile polygon parts.
  ///
  /// The format expects each exterior ring to be followed immediately by its
  /// own holes, so a single feature can carry several disjoint areas. Holes
  /// that fall inside no exterior ring are dropped rather than guessed at.
  static List<List<MvtPoint>> nest(
    List<List<MvtPoint>> outers,
    List<List<MvtPoint>> inners,
  ) {
    if (outers.isEmpty) return const [];

    final oriented = [for (final o in outers) orient(o, exterior: true)];
    final holesFor = List.generate(oriented.length, (_) => <List<MvtPoint>>[]);

    for (final inner in inners) {
      if (inner.length < 3) continue;
      final owner = _ownerOf(oriented, inner);
      if (owner < 0) continue;
      holesFor[owner].add(orient(inner, exterior: false));
    }

    return [
      for (var i = 0; i < oriented.length; i++) ...[
        oriented[i],
        ...holesFor[i],
      ],
    ];
  }

  /// Index of the smallest exterior ring containing [inner], or -1.
  ///
  /// Smallest, because rings nest: an island in a lake on an island. Choosing
  /// the largest container would punch the hole through the outermost shape.
  static int _ownerOf(List<List<MvtPoint>> outers, List<MvtPoint> inner) {
    var best = -1;
    var bestArea = 0;

    for (var i = 0; i < outers.length; i++) {
      if (!containsPoint(outers[i], inner.first)) continue;
      final area = MvtGeometryEncoder.doubledSignedArea(outers[i]).abs();
      if (best < 0 || area < bestArea) {
        best = i;
        bestArea = area;
      }
    }

    return best;
  }
}
