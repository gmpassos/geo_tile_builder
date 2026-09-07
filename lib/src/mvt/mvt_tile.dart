/// Geometry kinds defined by the Mapbox Vector Tile specification.
///
/// The numeric [value]s are the wire values of the spec's `GeomType` enum and
/// must not be renumbered.
enum MvtGeomType {
  unknown(0),
  point(1),
  lineString(2),
  polygon(3);

  /// Wire value written to the tile.
  final int value;

  const MvtGeomType(this.value);
}

/// A single vertex in **tile-local integer coordinates**.
///
/// The origin is the tile's top-left corner and the axes run right and *down*,
/// with the tile spanning `0 .. extent` on both (see [MvtLayer.extent]).
/// Coordinates outside that range are legal and describe geometry in the
/// tile's buffer — renderers clip them — but they must stay within
/// ±(2^31 - 1), which is the limit of the spec's parameter encoding.
class MvtPoint {
  final int x;
  final int y;

  const MvtPoint(this.x, this.y);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MvtPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'MvtPoint($x, $y)';
}

/// One feature: a geometry, an optional id, and a flat attribute map.
///
/// [parts] carries the geometry in a single shape for every [type], because
/// the wire encoding treats them uniformly as a sequence of point runs:
///
/// * [MvtGeomType.point] — exactly one part holding one or more points.
/// * [MvtGeomType.lineString] — one part per line; each needs >= 2 points.
/// * [MvtGeomType.polygon] — one part per ring, the exterior ring first and
///   its holes after it. Rings are **not** closed by repeating the first
///   point; the encoder emits a `ClosePath` command instead. A ring that does
///   repeat its first point is accepted and the duplicate dropped.
///
/// Attribute values may be [String], [int], [double] or [bool]; anything else
/// is rejected at encode time. Keys and values are dictionary-encoded per
/// layer, so repeating the same value across many features is cheap — which is
/// exactly what a road `class` attribute does.
class MvtFeature {
  /// Optional feature id. Should be unique within its layer when present.
  final int? id;

  final MvtGeomType type;

  /// Point runs — rings for polygons, lines for linestrings. See the class
  /// doc for the per-type shape.
  final List<List<MvtPoint>> parts;

  final Map<String, Object?> attributes;

  const MvtFeature({
    required this.type,
    required this.parts,
    this.id,
    this.attributes = const {},
  });

  @override
  String toString() =>
      'MvtFeature(${type.name}, ${parts.length} part(s), $attributes)';
}

/// A named layer of features sharing one coordinate extent.
class MvtLayer {
  /// Layer name, unique within a tile. This is what a style's `source-layer`
  /// refers to.
  final String name;

  /// Coordinate extent of the tile grid.
  ///
  /// 4096 is the near-universal default: coordinates then address 1/4096th of
  /// the tile, which is well under a pixel at any sane zoom. Lowering it is a
  /// real size lever — the deltas get smaller and so do their varints — at the
  /// cost of visible vertex snapping.
  final int extent;

  final List<MvtFeature> features;

  const MvtLayer({
    required this.name,
    required this.features,
    this.extent = 4096,
  });

  @override
  String toString() => 'MvtLayer($name, ${features.length} feature(s))';
}

/// A whole vector tile: an ordered set of named layers.
class MvtTile {
  final List<MvtLayer> layers;

  const MvtTile({this.layers = const []});

  /// Whether this tile carries no features at all.
  ///
  /// Empty tiles should be dropped rather than written — an absent tile and an
  /// empty one render identically, and the absent one costs nothing.
  bool get isEmpty => layers.every((l) => l.features.isEmpty);

  @override
  String toString() => 'MvtTile(${layers.length} layer(s))';
}
