import 'dart:io';
import 'dart:typed_data';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import '../geometry/clip.dart';
import '../geometry/mercator.dart';
import '../geometry/ring_builder.dart';
import '../geometry/simplify.dart';
import '../mvt/mvt_encoder.dart';
import '../mvt/mvt_tile.dart';
import '../osm/node_store.dart';
import '../pmtiles/pmtiles_header.dart';
import '../pmtiles/pmtiles_writer.dart';
import '../pmtiles/tile_id.dart';
import '../schema/tile_schema.dart';

/// What a build produced, for reporting and for tests.
class TileBuildReport {
  /// Source ways the schema kept.
  final int keptWays;

  /// Node ids the kept ways referenced.
  final int referencedNodes;

  /// Node coordinates actually resolved. Lower than [referencedNodes] when the
  /// extract references nodes outside its own boundary.
  final int resolvedNodes;

  /// Tiles that ended up with at least one feature.
  ///
  /// Zero means the archive is empty — nothing matched the schema, or nothing
  /// fell inside the requested bounds. The file is still written, but its
  /// directory has no entries and strict readers reject such an archive, so
  /// treat a zero here as a failed build rather than a small one.
  final int tiles;

  /// Features written, counted once per tile they appear in.
  final int features;

  final int minZoom;
  final int maxZoom;

  /// Size of the finished archive.
  final int archiveBytes;

  const TileBuildReport({
    required this.keptWays,
    required this.referencedNodes,
    required this.resolvedNodes,
    required this.tiles,
    required this.features,
    required this.minZoom,
    required this.maxZoom,
    required this.archiveBytes,
  });

  @override
  String toString() =>
      'TileBuildReport($keptWays ways, $tiles tiles, $features features, '
      '$archiveBytes bytes)';
}

/// Builds a PMTiles archive from an OpenStreetMap extract.
///
/// The pipeline, in order:
///
/// 1. **Relations pass.** Multipolygons the [TileSchema] wants are noted, along
///    with the ways they are built from. This comes first because those member
///    ways usually carry no tags of their own — nothing about a way says it is
///    part of a lake, so which geometry to retain is only knowable once the
///    relations are known.
/// 2. **Ways pass.** Every way is offered to the schema; the ones it keeps are
///    retained with their classification, as are any that a kept relation is
///    built from. Node ids are collected. Nodes themselves are not touched.
/// 3. **Nodes pass.** Only the coordinates the earlier passes asked for are
///    kept, in the flat arrays of a [NodeStore].
/// 4. **Per zoom.** Each kept feature is projected once into world coordinates
///    at that zoom, simplified once, then clipped into each tile it touches.
///    Projecting per zoom rather than per tile is what keeps the trigonometry
///    off the inner loop.
/// 5. **Write.** Tiles are encoded and appended in tile-id order, so the
///    archive is clustered and deduplicated.
///
/// The passes read the file three times and keep every kept feature in memory.
/// That is appropriate at the city scale this package targets; the memory that
/// actually matters — node coordinates — is already flat and typed.
class TileBuilder {
  final TileSchema schema;
  final OsmPbfParser parser;

  /// Tile-local padding kept beyond each tile edge, so lines join cleanly
  /// across seams.
  ///
  /// Null means *proportional to the schema's extent* — a 64th of a tile,
  /// which is 64 units at the usual extent of 4096. A fixed buffer is a trap
  /// at other extents: at extent 1024 a buffer of 64 is a sixteenth of the
  /// tile rather than a sixty-fourth, so features spill into neighbouring
  /// tiles that do not need them and the archive grows instead of shrinking.
  final int? buffer;

  const TileBuilder({
    required this.schema,
    this.parser = const OsmPbfParser(),
    this.buffer,
  });

  /// The buffer actually used, in tile-extent units.
  int get effectiveBuffer => buffer ?? (schema.extent ~/ 64);

  /// Reads [inputFile] and writes a PMTiles archive to [outputFile].
  ///
  /// [bounds] restricts output to a service area. Clipping to the area actually
  /// delivered to, rather than to whatever rectangle the extract happened to
  /// come in, is usually the largest single size saving available.
  Future<TileBuildReport> build({
    required String inputFile,
    required String outputFile,
    OsmBoundingBox? bounds,
    void Function(String stage)? onProgress,
  }) async {
    final area = bounds ?? (await parser.readHeader(inputFile))?.bbox;
    if (area == null) {
      throw ArgumentError(
        'no bounds given and $inputFile declares no bounding box; '
        'pass `bounds` explicitly',
      );
    }

    // Relations first, because a multipolygon's member ways usually carry no
    // tags of their own — nothing about the ways says they are part of a lake,
    // so the geometry to retain is only knowable once the relations are known.
    onProgress?.call('reading relations');
    final relations = await _readRelations(inputFile);

    onProgress?.call('reading ways');
    final (features, nodeIds) = await _readWays(inputFile, relations);

    onProgress?.call('assembling areas');
    features.addAll(_assembleRelations(relations));

    onProgress?.call('reading nodes');
    final nodes = NodeStore(nodeIds.sortedUnique());
    final points = <_PointFeature>[];
    await parser.parse(
      inputFile,
      readWays: false,
      readRelations: false,
      onNode: (node) => nodes.set(node.id, node.lat, node.lon),
      // Only decode the node tag stream when the schema actually wants it.
      onTaggedNode: !schema.readsNodes
          ? null
          : (node) {
              final classified = schema.node(node);
              if (classified == null) return;
              points.add(
                _PointFeature(node.id, node.lon, node.lat, classified),
              );
            },
    );

    onProgress?.call('building tiles');
    final writer = PmTilesWriter(
      tileType: PmTilesTileType.mvt,
      metadata: _metadata(area),
      minLon: area.minLon,
      minLat: area.minLat,
      maxLon: area.maxLon,
      maxLat: area.maxLat,
      centerLon: (area.minLon + area.maxLon) / 2,
      centerLat: (area.minLat + area.maxLat) / 2,
      centerZoom: (schema.minZoom + schema.maxZoom) ~/ 2,
    );

    const encoder = MvtEncoder();
    var tileCount = 0;
    var featureCount = 0;

    for (var zoom = schema.minZoom; zoom <= schema.maxZoom; zoom++) {
      onProgress?.call('zoom $zoom');
      final tiles = _binZoom(features, nodes, zoom, area);
      _binPoints(points, tiles, zoom, area);

      // Within a zoom, ascending tile id; zooms ascend too, so the whole
      // sequence is ascending as the writer requires.
      final ids = tiles.keys.toList()..sort();
      for (final id in ids) {
        final tile = _assemble(tiles[id]!);
        if (tile.isEmpty) continue;
        final bytes = encoder.encode(tile);
        if (bytes.isEmpty) continue;
        writer.add(id, bytes);
        tileCount++;
        featureCount += tiles[id]!.length;
      }
    }

    final archive = writer.build();
    await _write(outputFile, archive);

    return TileBuildReport(
      keptWays: features.length,
      referencedNodes: nodes.length,
      resolvedNodes: nodes.filled,
      tiles: tileCount,
      features: featureCount,
      minZoom: schema.minZoom,
      maxZoom: schema.maxZoom,
      archiveBytes: archive.length,
    );
  }

  /// Pass one: the relations the schema wants, and the ways they are built of.
  Future<List<_PendingRelation>> _readRelations(String inputFile) async {
    final pending = <_PendingRelation>[];

    await parser.parse(
      inputFile,
      readNodes: false,
      readWays: false,
      onRelation: (relation) {
        final classified = schema.relation(relation);
        if (classified == null) return;

        // Only way members contribute geometry. A node member (a label point,
        // say) has nothing to add to a ring.
        final members = [
          for (final m in relation.members)
            if (m.type == GeoMemberType.way) (m.ref, m.role),
        ];
        if (members.isEmpty) return;

        pending.add(_PendingRelation(relation.id, classified, members));
      },
    );

    return pending;
  }

  /// Pass two: classify ways, and retain the geometry of any way a kept
  /// relation is built from, whether or not the schema wanted the way itself.
  Future<(List<_SourceFeature>, NodeIdCollector)> _readWays(
    String inputFile,
    List<_PendingRelation> relations,
  ) async {
    final features = <_SourceFeature>[];
    final nodeIds = NodeIdCollector();

    final memberIds = <int>{
      for (final r in relations)
        for (final (ref, _) in r.members) ref,
    };

    await parser.parse(
      inputFile,
      readNodes: false,
      readRelations: false,
      onWay: (way) {
        var wanted = false;

        if (memberIds.contains(way.id)) {
          for (final relation in relations) {
            relation.geometry[way.id] = way.nodeIds;
          }
          wanted = true;
        }

        final classified = schema.way(way);
        if (classified != null) {
          features.add(
            _SourceFeature(way.id, [
              _asPart(way.nodeIds, classified.type),
            ], classified),
          );
          wanted = true;
        }

        if (wanted) nodeIds.addAll(way.nodeIds);
      },
    );

    return (features, nodeIds);
  }

  /// A closed way used as an area repeats its first node; rings do not.
  List<int> _asPart(List<int> nodeIds, MvtGeomType type) {
    if (type != MvtGeomType.polygon) return nodeIds;
    if (nodeIds.length > 1 && nodeIds.first == nodeIds.last) {
      return nodeIds.sublist(0, nodeIds.length - 1);
    }
    return nodeIds;
  }

  /// Joins each kept relation's member ways into rings.
  ///
  /// A relation whose outer ring cannot be closed produces nothing: an
  /// unclosed boundary is not an area, and guessing at one draws a shape that
  /// is not in the data.
  List<_SourceFeature> _assembleRelations(List<_PendingRelation> relations) {
    final out = <_SourceFeature>[];

    for (final relation in relations) {
      final outerFragments = <List<int>>[];
      final innerFragments = <List<int>>[];

      for (final (ref, role) in relation.members) {
        final geometry = relation.geometry[ref];
        if (geometry == null || geometry.length < 2) continue;
        // An empty role means outer: old-style multipolygons leave it off.
        if (role == 'inner') {
          innerFragments.add(geometry);
        } else {
          outerFragments.add(geometry);
        }
      }

      final outer = RingBuilder.assemble(outerFragments);
      if (outer.isEmpty) continue;

      out.add(
        _SourceFeature(
          relation.id,
          outer,
          relation.classified,
          inner: RingBuilder.assemble(innerFragments),
        ),
      );
    }

    return out;
  }

  /// Projects, simplifies and clips every feature into the tiles it touches at
  /// [zoom].
  Map<int, List<_TileFeature>> _binZoom(
    List<_SourceFeature> features,
    NodeStore nodes,
    int zoom,
    OsmBoundingBox area,
  ) {
    final extent = schema.extent;
    final tolerance = schema.simplificationAt(zoom);
    final buffer = effectiveBuffer;
    final rect = ClipRect.tile(extent: extent, buffer: buffer);
    final out = <int, List<_TileFeature>>{};

    // Only tiles inside the service area are worth producing.
    final (areaMinX, areaMinY, areaMaxX, areaMaxY) = _areaTileRange(area, zoom);

    for (final feature in features) {
      if (zoom < feature.classified.minZoom) continue;

      final polygon = feature.classified.type == MvtGeomType.polygon;
      // A ring needs three vertices to be an area; a line needs two.
      final minimum = polygon ? 3 : 2;

      final outer = _prepare(
        feature.outer,
        nodes,
        zoom,
        extent,
        tolerance,
        minimum,
      );
      if (outer.isEmpty) continue;

      final inner = _prepare(
        feature.inner,
        nodes,
        zoom,
        extent,
        tolerance,
        minimum,
      );

      var minX = outer.first.first.x, maxX = minX;
      var minY = outer.first.first.y, maxY = minY;
      for (final part in outer) {
        for (final p in part) {
          if (p.x < minX) minX = p.x;
          if (p.x > maxX) maxX = p.x;
          if (p.y < minY) minY = p.y;
          if (p.y > maxY) maxY = p.y;
        }
      }

      final (tx0, ty0, tx1, ty1) = Mercator.tileRangeOfWorld(
        minX - buffer,
        minY - buffer,
        maxX + buffer,
        maxY + buffer,
        zoom,
        extent: extent,
      );

      for (var tx = tx0; tx <= tx1; tx++) {
        if (tx < areaMinX || tx > areaMaxX) continue;
        for (var ty = ty0; ty <= ty1; ty++) {
          if (ty < areaMinY || ty > areaMaxY) continue;

          final tile = Zxy(zoom, tx, ty);
          List<MvtPoint> local(List<MvtPoint> part) => [
            for (final p in part) Mercator.toLocal(p, tile, extent: extent),
          ];

          final List<List<MvtPoint>> cleaned;
          if (polygon) {
            // Rings are clipped whole and re-nested, because clipping can drop
            // a hole entirely or cut an area down to nothing.
            final clippedOuter = [
              for (final part in outer)
                if (Clip.ring(local(part), rect) case final r
                    when r.length >= 3)
                  r,
            ];
            if (clippedOuter.isEmpty) continue;

            final clippedInner = [
              for (final part in inner)
                if (Clip.ring(local(part), rect) case final r
                    when r.length >= 3)
                  r,
            ];

            cleaned = RingBuilder.nest(clippedOuter, clippedInner);
          } else {
            cleaned = [
              for (final part in outer)
                for (final run in Clip.polyline(local(part), rect))
                  if (Simplify.dedupe(run).length >= 2) Simplify.dedupe(run),
            ];
          }

          if (cleaned.isEmpty) continue;

          (out[TileId.of(tile)] ??= []).add(
            _TileFeature(feature.id, feature.classified, cleaned),
          );
        }
      }
    }

    return out;
  }

  /// Places point features into the single tile that contains each one.
  ///
  /// Unlike a line or an area, a point cannot straddle a boundary, so there is
  /// nothing to clip and no buffer to honour: it lands in exactly one tile.
  void _binPoints(
    List<_PointFeature> points,
    Map<int, List<_TileFeature>> tiles,
    int zoom,
    OsmBoundingBox area,
  ) {
    if (points.isEmpty) return;

    final extent = schema.extent;
    final (areaMinX, areaMinY, areaMaxX, areaMaxY) = _areaTileRange(area, zoom);

    for (final point in points) {
      if (zoom < point.classified.minZoom) continue;

      final tile = Mercator.tileAt(point.lon, point.lat, zoom);
      if (tile.x < areaMinX || tile.x > areaMaxX) continue;
      if (tile.y < areaMinY || tile.y > areaMaxY) continue;

      final local = Mercator.project(
        point.lon,
        point.lat,
        tile,
        extent: extent,
      );

      (tiles[TileId.of(tile)] ??= []).add(
        _TileFeature(point.id, point.classified, [
          [local],
        ]),
      );
    }
  }

  /// Projects and simplifies each part, dropping any left too small to draw.
  List<List<MvtPoint>> _prepare(
    List<List<int>> parts,
    NodeStore nodes,
    int zoom,
    int extent,
    int tolerance,
    int minimum,
  ) {
    final out = <List<MvtPoint>>[];
    for (final part in parts) {
      final world = _project(part, nodes, zoom, extent);
      if (world.length < minimum) continue;
      final simplified = Simplify.dedupe(
        Simplify.douglasPeucker(world, tolerance),
      );
      if (simplified.length < minimum) continue;
      out.add(simplified);
    }
    return out;
  }

  /// Resolves a way's node ids into world coordinates, dropping any the
  /// extract did not contain.
  List<MvtPoint> _project(
    List<int> nodeIds,
    NodeStore nodes,
    int zoom,
    int extent,
  ) {
    final out = <MvtPoint>[];
    for (final id in nodeIds) {
      final coordinate = nodes.coordinateOf(id);
      if (coordinate == null) continue;
      final (lon, lat) = coordinate;
      out.add(Mercator.world(lon, lat, zoom, extent: extent));
    }
    return out;
  }

  (int, int, int, int) _areaTileRange(OsmBoundingBox area, int zoom) {
    final topLeft = Mercator.tileAt(area.minLon, area.maxLat, zoom);
    final bottomRight = Mercator.tileAt(area.maxLon, area.minLat, zoom);
    return (topLeft.x, topLeft.y, bottomRight.x, bottomRight.y);
  }

  /// Groups a tile's features into layers, lowest sort rank first.
  MvtTile _assemble(List<_TileFeature> features) {
    final byLayer = <String, List<MvtFeature>>{};

    final ordered = [...features]
      ..sort((a, b) => a.classified.sortRank.compareTo(b.classified.sortRank));

    for (final feature in ordered) {
      (byLayer[feature.classified.layer] ??= []).add(
        MvtFeature(
          id: feature.id,
          type: feature.classified.type,
          parts: feature.parts,
          attributes: feature.classified.attributes,
        ),
      );
    }

    return MvtTile(
      layers: [
        for (final entry in byLayer.entries)
          MvtLayer(
            name: entry.key,
            extent: schema.extent,
            features: entry.value,
          ),
      ],
    );
  }

  Map<String, Object?> _metadata(OsmBoundingBox area) => {
    'name': schema.name,
    'format': 'pbf',
    'type': 'overlay',
    'minzoom': schema.minZoom,
    'maxzoom': schema.maxZoom,
    'bounds': '${area.minLon},${area.minLat},${area.maxLon},${area.maxLat}',
    'vector_layers': [for (final l in schema.layers) l.toMetadata()],
  };

  static Future<void> _write(String path, Uint8List bytes) =>
      File(path).writeAsBytes(bytes, flush: true);
}

/// A relation the schema kept, waiting for its member geometry.
class _PendingRelation {
  final int id;
  final ClassifiedFeature classified;

  /// Way members as `(id, role)`, in the order the relation listed them.
  final List<(int, String)> members;

  /// Member way id to its node ids, filled in during the ways pass.
  final Map<int, List<int>> geometry = {};

  _PendingRelation(this.id, this.classified, this.members);
}

/// A feature the schema kept, still in node-id space.
class _SourceFeature {
  final int id;

  /// A line's vertices, or a polygon's exterior rings.
  final List<List<int>> outer;

  /// Interior rings. Always empty for lines.
  final List<List<int>> inner;

  final ClassifiedFeature classified;

  const _SourceFeature(
    this.id,
    this.outer,
    this.classified, {
    this.inner = const [],
  });
}

/// A tagged node the schema kept, carrying its own coordinate.
///
/// Points do not go through the [NodeStore]: that table is sized from ids
/// collected while reading ways, and a tagged node is only discovered later,
/// during the node pass itself.
class _PointFeature {
  final int id;
  final double lon;
  final double lat;
  final ClassifiedFeature classified;

  const _PointFeature(this.id, this.lon, this.lat, this.classified);
}

/// A feature clipped into one tile.
class _TileFeature {
  final int id;
  final ClassifiedFeature classified;
  final List<List<MvtPoint>> parts;

  const _TileFeature(this.id, this.classified, this.parts);
}
