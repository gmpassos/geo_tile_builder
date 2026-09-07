import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import '../mvt/mvt_tile.dart';
import 'tile_schema.dart';

/// A deliberately impoverished schema for turn-by-turn and delivery maps.
///
/// It keeps what a rider looking at a route actually needs — the road network,
/// its names, water to orient by — and discards everything else: landuse,
/// buildings, points of interest, boundaries, contours, aeroways. Attributes
/// are cut to `class` and `name`, and every feature class earns a minimum zoom
/// rather than appearing everywhere.
///
/// The point is not that this map is *good* in general. It is that no
/// general-purpose tiler is allowed to be this ruthless, and the resulting
/// archive is small enough to ship to a phone and use with no network.
class DeliverySchema implements TileSchema {
  /// Layer carrying the road network.
  static const String roadLayer = 'road';

  /// Layer carrying water areas.
  static const String waterLayer = 'water';

  @override
  final int minZoom;

  @override
  final int maxZoom;

  @override
  final int extent;

  /// Whether to carry street names. Names dominate a road layer's size, so a
  /// pack meant purely for orientation can drop them.
  final bool includeNames;

  const DeliverySchema({
    this.minZoom = 6,
    this.maxZoom = 15,
    this.extent = 4096,
    this.includeNames = true,
  });

  @override
  String get name => 'delivery';

  @override
  List<TileLayerSpec> get layers => [
    TileLayerSpec(
      id: roadLayer,
      minZoom: minZoom,
      maxZoom: maxZoom,
      description: 'Road network, classified for rendering weight.',
      fields: {'class': 'String', if (includeNames) 'name': 'String'},
    ),
    TileLayerSpec(
      id: waterLayer,
      minZoom: minZoom,
      maxZoom: maxZoom,
      description: 'Water areas, for orientation.',
      fields: const {'class': 'String'},
    ),
  ];

  /// OSM `highway` values collapsed into the handful of weights a map actually
  /// draws differently, with the zoom each first earns its place at.
  ///
  /// The zooms are the size lever: a service road emitted from z6 would be
  /// carried through ten zoom levels that will never display it.
  static const Map<String, (String, int)> _highways = {
    'motorway': ('motorway', 6),
    'motorway_link': ('motorway', 12),
    'trunk': ('trunk', 6),
    'trunk_link': ('trunk', 12),
    'primary': ('primary', 8),
    'primary_link': ('primary', 12),
    'secondary': ('secondary', 10),
    'secondary_link': ('secondary', 12),
    'tertiary': ('tertiary', 11),
    'tertiary_link': ('tertiary', 13),
    'residential': ('minor', 13),
    'unclassified': ('minor', 13),
    'living_street': ('minor', 14),
    'service': ('service', 14),
    'pedestrian': ('path', 14),
    'footway': ('path', 15),
    'path': ('path', 15),
    'cycleway': ('path', 15),
    'track': ('path', 15),
    'steps': ('path', 15),
  };

  /// Drawing order within the road layer: motorways over minor streets.
  static const Map<String, int> _rank = {
    'path': 0,
    'service': 1,
    'minor': 2,
    'tertiary': 3,
    'secondary': 4,
    'primary': 5,
    'trunk': 6,
    'motorway': 7,
  };

  /// `natural`/`waterway` values kept as water.
  static const Set<String> _waterValues = {'water', 'bay', 'strait'};

  @override
  ClassifiedFeature? way(GeoWay way) {
    // A way needs at least two nodes to be a line at all.
    if (way.nodeIds.length < 2) return null;

    final highway = way.tags['highway'];
    if (highway != null) {
      final entry = _highways[highway];
      if (entry == null) return null;
      final (roadClass, zoom) = entry;
      final name = includeNames ? way.tags['name'] : null;

      return ClassifiedFeature(
        layer: roadLayer,
        type: MvtGeomType.lineString,
        minZoom: zoom < minZoom ? minZoom : zoom,
        sortRank: _rank[roadClass] ?? 0,
        attributes: {
          'class': roadClass,
          if (name != null && name.isNotEmpty) 'name': name,
        },
      );
    }

    // Closed ways tagged as water are areas; open ones are riverbanks we do
    // not draw.
    final natural = way.tags['natural'];
    if (natural != null && _waterValues.contains(natural)) {
      if (way.nodeIds.first != way.nodeIds.last) return null;
      return const ClassifiedFeature(
        layer: waterLayer,
        type: MvtGeomType.polygon,
        minZoom: 6,
        attributes: {'class': 'water'},
      );
    }

    return null;
  }

  /// No node ever becomes a feature: this schema has no place labels and no
  /// points of interest, which is a large part of why its tiles are small.
  @override
  ClassifiedFeature? node(GeoTaggedNode node) => null;

  /// Water multipolygons are the one relation worth having, and are only
  /// emitted once a builder can assemble rings from member ways.
  @override
  ClassifiedFeature? relation(GeoRelation relation) {
    if (!relation.isMultipolygon) return null;
    final natural = relation.tags['natural'];
    if (natural == null || !_waterValues.contains(natural)) return null;
    return const ClassifiedFeature(
      layer: waterLayer,
      type: MvtGeomType.polygon,
      minZoom: 6,
      attributes: {'class': 'water'},
    );
  }

  /// Tolerance in tile-extent units.
  ///
  /// Four units at extent 4096 is roughly a thousandth of a tile — under a
  /// pixel at any display size — so nothing visible is lost. Low zooms get a
  /// coarser tolerance because a tile there covers far more ground.
  @override
  int simplificationAt(int zoom) => zoom >= maxZoom ? 2 : 4;
}
