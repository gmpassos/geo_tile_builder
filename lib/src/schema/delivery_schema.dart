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

  /// Layer carrying the traffic controls a vehicle has to stop at.
  ///
  /// Points, not lines. A set of lights is a node on the road, and what a
  /// driver needs from it is the spot where they will have to stop — not
  /// anything about its shape.
  static const String signalLayer = 'signal';

  @override
  final int minZoom;

  @override
  final int maxZoom;

  @override
  final int extent;

  /// Whether to carry street names.
  ///
  /// Worth about 15% of the archive in practice — less than it looks, because
  /// names are dictionary-encoded per layer and a street's name repeats across
  /// every tile and zoom it appears in. Drop them for a pack meant purely for
  /// orientation, but do not expect them to be the reason a pack is large.
  final bool includeNames;

  /// Whether to carry traffic controls — lights, stop and give-way signs,
  /// level crossings.
  ///
  /// **This is the one option that changes what the build costs to run**, and
  /// it is worth understanding before turning it off to save space. The tiles
  /// it adds are small: these are points with one short attribute, there are a
  /// few thousand in a city against a road network of hundreds of thousands of
  /// segments, and they start at [signalMinZoom] rather than at [minZoom].
  ///
  /// The expense is upstream of the tiles. Node tags live in a packed stream
  /// that a reader can skip entirely, so a schema that wants *any* node pays
  /// to decode tens of millions of entries that are almost all untagged shape
  /// points — see [readsNodes]. That cost is per build, not per pack byte.
  ///
  /// Default on, because a navigation map that cannot show a junction's lights
  /// is the thing this schema exists to serve.
  final bool includeSignals;

  const DeliverySchema({
    this.minZoom = 6,
    this.maxZoom = 15,
    this.extent = 4096,
    this.includeNames = true,
    this.includeSignals = true,
  });

  /// Where traffic controls start being drawn.
  ///
  /// Late, and deliberately. A set of lights is meaningless on a map of a
  /// whole city — it is worth drawing when the driver is close enough to stop
  /// at it, which is the zoom guidance actually uses. Emitting them from
  /// [minZoom] would carry a few thousand points through eight zoom levels
  /// that will never display one.
  static const int signalMinZoom = 14;

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
    if (includeSignals)
      TileLayerSpec(
        id: signalLayer,
        minZoom: signalMinZoom,
        maxZoom: maxZoom,
        description:
            'Traffic controls a vehicle stops at: lights, stop and give-way '
            'signs, level crossings.',
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

  /// The traffic controls kept, and what each is called in a tile.
  ///
  /// Four values, not the dozen OSM offers, and the line is drawn at **things
  /// that stop a vehicle**. A driver plans around a set of lights; they do not
  /// plan around a street lamp, a bus stop or a speed camera, and every extra
  /// tag is points in every tile of every city for ever.
  ///
  /// `highway=crossing` is the notable exclusion. It is a pedestrian crossing
  /// with no signal of its own — there are several per block, they would
  /// outnumber every other control here by an order of magnitude, and at
  /// navigation speed the result is a map peppered with dots that mean nothing
  /// to the person reading it. A *signalised* crossing is tagged
  /// `crossing=traffic_signals` and is caught below.
  static const Map<String, String> _highwaySignals = {
    'traffic_signals': 'traffic_signals',
    'stop': 'stop',
    'give_way': 'give_way',
  };

  /// No node ever becomes a feature unless [includeSignals] is on.
  ///
  /// Declared rather than discovered, and not free: node tags live in a packed
  /// stream a reader can otherwise skip entirely, so saying yes here means
  /// decoding tens of millions of entries that are almost all untagged shape
  /// points.
  @override
  bool get readsNodes => includeSignals;

  @override
  ClassifiedFeature? node(GeoTaggedNode node) {
    if (!includeSignals) return null;

    final signal = _signalClass(node.tags);
    if (signal == null) return null;

    return ClassifiedFeature(
      layer: signalLayer,
      type: MvtGeomType.point,
      minZoom: signalMinZoom < minZoom ? minZoom : signalMinZoom,
      attributes: {'class': signal},
    );
  }

  /// What kind of control this node is, or null for anything else.
  static String? _signalClass(Map<String, String> tags) {
    // A railway level crossing first: it is tagged on the railway rather than
    // the highway, and it is the one control here that can hold a rider for
    // minutes rather than seconds.
    final railway = tags['railway'];
    if (railway == 'level_crossing' || railway == 'crossing') {
      return 'level_crossing';
    }

    final highway = tags['highway'];

    // A signalised pedestrian crossing *is* a set of lights, and is tagged as
    // a crossing rather than as `highway=traffic_signals`. Catching it here is
    // what keeps the exclusion of plain crossings from also dropping the ones
    // that stop traffic.
    if (highway == 'crossing') {
      final crossing = tags['crossing'];
      return crossing == 'traffic_signals' || tags['crossing:signals'] == 'yes'
          ? 'traffic_signals'
          : null;
    }

    return highway == null ? null : _highwaySignals[highway];
  }

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
