import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import '../mvt/mvt_tile.dart';

/// One layer a schema can emit, as declared to styles.
///
/// This becomes an entry in the archive's `vector_layers` metadata, which is
/// how a style discovers what `source-layer` names and fields exist.
class TileLayerSpec {
  /// Layer name, matched by a style's `source-layer`.
  final String id;

  /// Attribute names to their type, as the metadata spells them: `String`,
  /// `Number` or `Boolean`.
  final Map<String, String> fields;

  /// Lowest zoom at which this layer carries anything.
  final int minZoom;

  /// Highest zoom at which this layer carries anything.
  final int maxZoom;

  final String? description;

  const TileLayerSpec({
    required this.id,
    this.fields = const {},
    required this.minZoom,
    required this.maxZoom,
    this.description,
  });

  /// The `vector_layers` entry for this layer.
  Map<String, Object?> toMetadata() => {
    'id': id,
    'fields': fields,
    'minzoom': minZoom,
    'maxzoom': maxZoom,
    if (description != null) 'description': description,
  };

  @override
  String toString() => 'TileLayerSpec($id, z$minZoom-$maxZoom)';
}

/// A source feature that a schema decided to keep, and how to draw it.
class ClassifiedFeature {
  /// Target layer name. Must be one of the schema's [TileSchema.layers].
  final String layer;

  final MvtGeomType type;

  /// Attributes to carry into the tile. Keep this vocabulary small and
  /// repetitive — values are dictionary-encoded per layer, so a handful of
  /// repeated strings costs almost nothing while free text costs a great deal.
  final Map<String, Object?> attributes;

  /// Lowest zoom at which this particular feature appears.
  ///
  /// This is the single most effective size lever a schema has. A motorway
  /// belongs at z6; a driveway does not belong until z15, and emitting it
  /// sooner multiplies its cost across every intervening zoom.
  final int minZoom;

  /// Optional ordering hint within its layer, lowest drawn first.
  final int sortRank;

  const ClassifiedFeature({
    required this.layer,
    required this.type,
    required this.minZoom,
    this.attributes = const {},
    this.sortRank = 0,
  });

  @override
  String toString() =>
      'ClassifiedFeature($layer, ${type.name}, z$minZoom+, $attributes)';
}

/// Decides what goes into the tiles, and at which zooms.
///
/// This is the package's central extension point, and the reason it can produce
/// tiles far smaller than a general-purpose tiler: a schema is *allowed to throw
/// almost everything away*. A general tiler must serve every use case and so
/// cannot drop a feature anyone might want; a schema written for one product can
/// keep five layers, a couple of attributes and a narrow zoom range, and that
/// difference is orders of magnitude rather than percentages.
///
/// Implement this to describe your own map. The bundled [DeliverySchema] is a
/// worked example, not a default anyone must accept.
///
/// ```dart
/// class MySchema implements TileSchema {
///   @override
///   ClassifiedFeature? way(GeoWay way) {
///     if (way.tags['railway'] == null) return null;
///     return const ClassifiedFeature(
///       layer: 'rail',
///       type: MvtGeomType.lineString,
///       minZoom: 10,
///     );
///   }
///   // …
/// }
/// ```
abstract interface class TileSchema {
  /// Short identifier, recorded in the archive metadata.
  String get name;

  /// Lowest zoom the schema produces tiles for.
  int get minZoom;

  /// Highest zoom the schema produces tiles for.
  int get maxZoom;

  /// Coordinate extent of each tile. Lowering it below 4096 shrinks coordinate
  /// deltas — a real size lever — at the cost of visible vertex snapping.
  int get extent;

  /// Every layer this schema may emit.
  List<TileLayerSpec> get layers;

  /// Classifies a way, or returns null to drop it.
  ClassifiedFeature? way(GeoWay way);

  /// Classifies a tagged node, or returns null to drop it.
  ClassifiedFeature? node(GeoTaggedNode node);

  /// Classifies a relation, or returns null to drop it.
  ///
  /// Relations become areas only once their member ways have been assembled
  /// into rings, so a schema that returns non-null here is asking for work a
  /// builder may not yet do.
  ClassifiedFeature? relation(GeoRelation relation);

  /// Simplification tolerance at [zoom], in tile-extent units.
  ///
  /// Vertices closer together than this are indistinguishable once drawn, and
  /// dropping them is the cheapest size win available. Returning `0` disables
  /// simplification at that zoom.
  int simplificationAt(int zoom);
}
