import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import '../mvt/mvt_tile.dart';
import 'tile_schema.dart';

/// A subset of the [OpenMapTiles schema](https://openmaptiles.org/schema/),
/// using its layer and field names.
///
/// The point of this schema is *compatibility*, not size. Because the layers
/// are named as OpenMapTiles names them — `transportation`, `place`, `water` —
/// an existing style such as Dark Matter, Positron or OSM Liberty renders the
/// output without modification, and degrades gracefully over the layers this
/// subset does not produce.
///
/// That is the trade against [DeliverySchema], which is much smaller but needs
/// a style written for it. Use this one when you want a map that looks like a
/// map on day one; use the delivery schema when the archive has to fit on a
/// phone.
///
/// **Not the whole schema.** Implemented: `transportation`,
/// `transportation_name`, `water`, `waterway`, `building` and `place`. Absent:
/// `landcover`, `landuse`, `poi`, `boundary`, `aeroway`, `park`,
/// `mountain_peak`, `housenumber`, `water_name`, `aerodrome_label`. A style
/// referencing those simply draws nothing for them.
class OpenMapTilesSchema implements TileSchema {
  @override
  final int minZoom;

  @override
  final int maxZoom;

  @override
  final int extent;

  /// Whether to emit the `building` layer, which is bulky and only appears at
  /// the highest zooms.
  final bool includeBuildings;

  const OpenMapTilesSchema({
    this.minZoom = 4,
    this.maxZoom = 14,
    this.extent = 4096,
    this.includeBuildings = true,
  });

  @override
  String get name => 'openmaptiles';

  @override
  bool get readsNodes => true;

  @override
  List<TileLayerSpec> get layers => [
    TileLayerSpec(
      id: 'transportation',
      minZoom: minZoom,
      maxZoom: maxZoom,
      description: 'Roads, railways and ferries.',
      fields: const {
        'class': 'String',
        'subclass': 'String',
        'brunnel': 'String',
        'oneway': 'Number',
      },
    ),
    TileLayerSpec(
      id: 'transportation_name',
      minZoom: 8,
      maxZoom: maxZoom,
      description: 'Names for the road network.',
      fields: const {'name': 'String', 'ref': 'String', 'class': 'String'},
    ),
    TileLayerSpec(
      id: 'water',
      minZoom: minZoom,
      maxZoom: maxZoom,
      description: 'Water areas.',
      fields: const {'class': 'String', 'intermittent': 'Number'},
    ),
    TileLayerSpec(
      id: 'waterway',
      minZoom: 9,
      maxZoom: maxZoom,
      description: 'Rivers, canals and streams as lines.',
      fields: const {'class': 'String', 'name': 'String'},
    ),
    if (includeBuildings)
      TileLayerSpec(
        id: 'building',
        minZoom: 13,
        maxZoom: maxZoom,
        description: 'Building footprints.',
        fields: const {'render_height': 'Number'},
      ),
    TileLayerSpec(
      id: 'place',
      minZoom: minZoom,
      maxZoom: maxZoom,
      description: 'Settlement labels.',
      fields: const {'class': 'String', 'name': 'String', 'rank': 'Number'},
    ),
  ];

  /// OSM `highway` to the OpenMapTiles `class`, with the zoom it starts at.
  static const Map<String, (String, int)> _highways = {
    'motorway': ('motorway', 4),
    'trunk': ('trunk', 5),
    'primary': ('primary', 7),
    'secondary': ('secondary', 9),
    'tertiary': ('tertiary', 10),
    'unclassified': ('minor', 12),
    'residential': ('minor', 12),
    'living_street': ('minor', 13),
    'service': ('service', 13),
    'track': ('track', 13),
    'pedestrian': ('path', 13),
    'path': ('path', 14),
    'footway': ('path', 14),
    'cycleway': ('path', 14),
    'steps': ('path', 14),
  };

  /// `place` values OpenMapTiles carries, with a rank and a starting zoom.
  ///
  /// Rank drives label priority in every OpenMapTiles style, so a capital does
  /// not lose its label to the village next door.
  static const Map<String, (int, int)> _places = {
    'continent': (1, 0),
    'country': (2, 2),
    'state': (3, 4),
    'city': (4, 5),
    'town': (5, 8),
    'village': (6, 11),
    'hamlet': (7, 13),
    'suburb': (8, 12),
    'neighbourhood': (9, 13),
    'island': (10, 10),
  };

  static const Set<String> _waterValues = {'water', 'bay', 'strait', 'lagoon'};

  static const Set<String> _waterwayClasses = {
    'stream',
    'river',
    'canal',
    'drain',
    'ditch',
  };

  @override
  ClassifiedFeature? way(GeoWay way) {
    if (way.nodeIds.length < 2) return null;
    final tags = way.tags;
    final closed =
        way.nodeIds.length > 3 && way.nodeIds.first == way.nodeIds.last;

    final highway = tags['highway'];
    if (highway != null) {
      // `_link` ramps carry their parent's class, as OpenMapTiles does.
      final base = highway.endsWith('_link')
          ? highway.substring(0, highway.length - 5)
          : highway;
      final entry = _highways[base];
      if (entry == null) return null;
      final (roadClass, zoom) = entry;

      return ClassifiedFeature(
        layer: 'transportation',
        type: MvtGeomType.lineString,
        minZoom: zoom < minZoom ? minZoom : zoom,
        attributes: {
          'class': roadClass,
          if (base != roadClass) 'subclass': base,
          'brunnel': ?_brunnelOf(tags),
          if (tags['oneway'] == 'yes') 'oneway': 1,
        },
      );
    }

    if (closed) {
      final natural = tags['natural'];
      if (natural != null && _waterValues.contains(natural)) {
        return const ClassifiedFeature(
          layer: 'water',
          type: MvtGeomType.polygon,
          minZoom: 0,
          attributes: {'class': 'lake'},
        );
      }
      if (tags['landuse'] == 'reservoir' || tags['water'] != null) {
        return const ClassifiedFeature(
          layer: 'water',
          type: MvtGeomType.polygon,
          minZoom: 0,
          attributes: {'class': 'lake'},
        );
      }
      if (includeBuildings && tags['building'] != null) {
        return ClassifiedFeature(
          layer: 'building',
          type: MvtGeomType.polygon,
          minZoom: 13,
          attributes: {'render_height': ?_heightOf(tags)},
        );
      }
    }

    final waterway = tags['waterway'];
    if (waterway != null && _waterwayClasses.contains(waterway)) {
      return ClassifiedFeature(
        layer: 'waterway',
        type: MvtGeomType.lineString,
        minZoom: waterway == 'river' ? 9 : 12,
        attributes: {
          'class': waterway,
          if (tags['name'] case final n? when n.isNotEmpty) 'name': n,
        },
      );
    }

    return null;
  }

  @override
  ClassifiedFeature? node(GeoTaggedNode node) {
    final place = node.tags['place'];
    if (place == null) return null;

    final entry = _places[place];
    if (entry == null) return null;
    final (rank, zoom) = entry;

    final name = node.tags['name'];
    if (name == null || name.isEmpty) return null;

    return ClassifiedFeature(
      layer: 'place',
      type: MvtGeomType.point,
      minZoom: zoom < minZoom ? minZoom : zoom,
      // Lower rank draws first; styles read it to break label collisions.
      sortRank: rank,
      attributes: {'class': place, 'name': name, 'rank': rank},
    );
  }

  @override
  ClassifiedFeature? relation(GeoRelation relation) {
    if (!relation.isMultipolygon) return null;
    final tags = relation.tags;

    final natural = tags['natural'];
    if (natural != null && _waterValues.contains(natural)) {
      return const ClassifiedFeature(
        layer: 'water',
        type: MvtGeomType.polygon,
        minZoom: 0,
        attributes: {'class': 'lake'},
      );
    }
    if (tags['landuse'] == 'reservoir' || tags['water'] != null) {
      return const ClassifiedFeature(
        layer: 'water',
        type: MvtGeomType.polygon,
        minZoom: 0,
        attributes: {'class': 'lake'},
      );
    }

    return null;
  }

  /// OpenMapTiles collapses bridges and tunnels into one `brunnel` field.
  static String? _brunnelOf(Map<String, String> tags) {
    if (tags['bridge'] != null && tags['bridge'] != 'no') return 'bridge';
    if (tags['tunnel'] != null && tags['tunnel'] != 'no') return 'tunnel';
    if (tags['ford'] != null && tags['ford'] != 'no') return 'ford';
    return null;
  }

  /// Building height in metres, from `height` or an estimate from levels.
  static double? _heightOf(Map<String, String> tags) {
    final height = double.tryParse(tags['height'] ?? '');
    if (height != null) return height;
    final levels = double.tryParse(tags['building:levels'] ?? '');
    // The conventional OpenMapTiles estimate: about 3.66 m per storey.
    if (levels != null) return levels * 3.66;
    return null;
  }

  @override
  int simplificationAt(int zoom) => zoom >= maxZoom ? 2 : 4;
}
