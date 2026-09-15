/// A high-performance, schema-agnostic, offline-first vector tile builder
/// written in pure Dart.
///
/// `geo_tile_builder` encodes [Mapbox Vector Tiles][mvt] and packages them into
/// [PMTiles][pmtiles] archives — the single-file format MapLibre reads natively
/// over `pmtiles://` on Android, iOS and the web. It is the rendering half of a
/// pair: its sibling `geo_route_finder` compiles the same OpenStreetMap extract
/// into a routing graph, so one download yields both the map a rider sees and
/// the routes drawn on it.
///
/// [mvt]: https://github.com/mapbox/vector-tile-spec
/// [pmtiles]: https://docs.protomaps.com/pmtiles/
///
/// Encoding a tile by hand:
///
/// ```dart
/// final tile = MvtTile(
///   layers: [
///     MvtLayer(
///       name: 'road',
///       features: [
///         MvtFeature(
///           type: MvtGeomType.lineString,
///           parts: [
///             [MvtPoint(0, 0), MvtPoint(1024, 512), MvtPoint(4096, 4096)],
///           ],
///           attributes: {'class': 'primary', 'name': '5ª Avenida'},
///         ),
///       ],
///     ),
///   ],
/// );
///
/// final bytes = const MvtEncoder().encode(tile);
/// ```
///
/// The package has **no runtime dependencies**: the protobuf wire format is
/// written directly by [PbfWriter], and compression uses `dart:io`'s codecs.
library;

// What version produced an artefact, for a builder that has to record it.
export 'src/version.dart';

// Protobuf wire format — the shared encoding primitive.
export 'src/pbf/pbf_writer.dart';

// Mapbox Vector Tile model and encoder.
export 'src/mvt/mvt_tile.dart';
export 'src/mvt/mvt_geometry.dart';
export 'src/mvt/mvt_encoder.dart';

// Geometry — projection, generalisation and clipping.
export 'src/geometry/mercator.dart';
export 'src/geometry/simplify.dart';
export 'src/geometry/clip.dart';
export 'src/geometry/ring_builder.dart';

// Schema — the extension point deciding what a map contains.
export 'src/schema/tile_schema.dart';
export 'src/schema/delivery_schema.dart';
export 'src/schema/open_map_tiles_schema.dart';

// OpenStreetMap pipeline.
export 'src/osm/node_store.dart';
export 'src/tiling/tile_builder.dart';

// PMTiles archive format.
export 'src/pmtiles/tile_id.dart';
export 'src/pmtiles/pmtiles_header.dart';
export 'src/pmtiles/pmtiles_directory.dart';
export 'src/pmtiles/pmtiles_writer.dart';
