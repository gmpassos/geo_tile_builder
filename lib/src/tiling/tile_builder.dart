import 'dart:io';
import 'dart:typed_data';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import '../geometry/clip.dart';
import '../geometry/mercator.dart';
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
/// 1. **Ways pass.** Every way is offered to the [TileSchema]; the ones it
///    keeps are retained with their classification, and their node ids are
///    collected. Nodes are not touched at all on this pass.
/// 2. **Nodes pass.** Only the coordinates the first pass asked for are kept,
///    in the flat arrays of a [NodeStore].
/// 3. **Per zoom.** Each kept feature is projected once into world coordinates
///    at that zoom, simplified once, then clipped into each tile it touches.
///    Projecting per zoom rather than per tile is what keeps the trigonometry
///    off the inner loop.
/// 4. **Write.** Tiles are encoded and appended in tile-id order, so the
///    archive is clustered and deduplicated.
///
/// The two passes read the file twice and keep every kept way in memory. That
/// is appropriate at the city scale this package targets; the memory that
/// actually matters — node coordinates — is already flat and typed.
class TileBuilder {
  final TileSchema schema;
  final OsmPbfParser parser;

  /// Tile-local padding kept beyond each tile edge, so lines join cleanly
  /// across seams.
  final int buffer;

  const TileBuilder({
    required this.schema,
    this.parser = const OsmPbfParser(),
    this.buffer = 64,
  });

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

    onProgress?.call('reading ways');
    final (features, nodeIds) = await _readWays(inputFile);

    onProgress?.call('reading nodes');
    final nodes = NodeStore(nodeIds.sortedUnique());
    await parser.parse(
      inputFile,
      readWays: false,
      readRelations: false,
      onNode: (node) => nodes.set(node.id, node.lat, node.lon),
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

  /// Pass one: classify ways, keeping only what the schema wants.
  Future<(List<_SourceFeature>, NodeIdCollector)> _readWays(
    String inputFile,
  ) async {
    final features = <_SourceFeature>[];
    final nodeIds = NodeIdCollector();

    await parser.parse(
      inputFile,
      readNodes: false,
      readRelations: false,
      onWay: (way) {
        final classified = schema.way(way);
        if (classified == null) return;
        features.add(_SourceFeature(way.id, way.nodeIds, classified));
        nodeIds.addAll(way.nodeIds);
      },
    );

    return (features, nodeIds);
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
    final rect = ClipRect.tile(extent: extent, buffer: buffer);
    final out = <int, List<_TileFeature>>{};

    // Only tiles inside the service area are worth producing.
    final (areaMinX, areaMinY, areaMaxX, areaMaxY) = _areaTileRange(area, zoom);

    for (final feature in features) {
      if (zoom < feature.classified.minZoom) continue;

      final world = _project(feature.nodeIds, nodes, zoom, extent);
      if (world.length < 2) continue;

      final simplified = Simplify.dedupe(
        Simplify.douglasPeucker(world, tolerance),
      );
      if (simplified.length < 2) continue;

      var minX = simplified.first.x, maxX = minX;
      var minY = simplified.first.y, maxY = minY;
      for (final p in simplified) {
        if (p.x < minX) minX = p.x;
        if (p.x > maxX) maxX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.y > maxY) maxY = p.y;
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
          final local = [
            for (final p in simplified)
              Mercator.toLocal(p, tile, extent: extent),
          ];

          final parts = Clip.polyline(local, rect);
          if (parts.isEmpty) continue;

          final cleaned = [
            for (final part in parts)
              if (Simplify.dedupe(part).length >= 2) Simplify.dedupe(part),
          ];
          if (cleaned.isEmpty) continue;

          (out[TileId.of(tile)] ??= []).add(
            _TileFeature(feature.id, feature.classified, cleaned),
          );
        }
      }
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

/// A way the schema kept, before any projection.
class _SourceFeature {
  final int id;
  final List<int> nodeIds;
  final ClassifiedFeature classified;

  const _SourceFeature(this.id, this.nodeIds, this.classified);
}

/// A feature clipped into one tile.
class _TileFeature {
  final int id;
  final ClassifiedFeature classified;
  final List<List<MvtPoint>> parts;

  const _TileFeature(this.id, this.classified, this.parts);
}
