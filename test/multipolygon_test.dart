import 'dart:io';
import 'dart:typed_data';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';
import 'package:geo_tile_builder/geo_tile_builder.dart';
import 'package:pmtiles/pmtiles.dart' as oracle;
import 'package:test/test.dart';

import 'support.dart';

/// A patch of ocean off Balneário Camboriú.
const _bbox = OsmBoundingBox(
  minLon: -48.66,
  minLat: -27.01,
  maxLon: -48.61,
  maxLat: -26.97,
);

/// A lake: a square outer boundary split into two ways, plus an island.
///
/// Split deliberately, and with the second fragment running backwards, because
/// that is what real relations look like.
final _lakeNodes = [
  // Outer square.
  const OsmNode(1, -27.000, -48.650),
  const OsmNode(2, -27.000, -48.620),
  const OsmNode(3, -26.980, -48.620),
  const OsmNode(4, -26.980, -48.650),
  // Island inside it.
  const OsmNode(11, -26.993, -48.640),
  const OsmNode(12, -26.993, -48.630),
  const OsmNode(13, -26.987, -48.630),
  const OsmNode(14, -26.987, -48.640),
];

final _lakeWays = [
  // Outer, first half.
  const OsmWay(100, [1, 2, 3], {}),
  // Outer, second half — written backwards, so it must be reversed to join.
  const OsmWay(101, [1, 4, 3], {}),
  // The island, closed on its own.
  const OsmWay(102, [11, 12, 13, 14, 11], {}),
];

final _lakeRelation = const OsmRelation(
  500,
  [OsmMember(100, 'outer'), OsmMember(101, 'outer'), OsmMember(102, 'inner')],
  {'type': 'multipolygon', 'natural': 'water'},
);

Future<(String, TileBuildReport)> _build({
  List<OsmWay> extraWays = const [],
  List<OsmRelation> relations = const [],
}) async {
  final input = writeTempOsmPbf(
    buildOsmPbf(
      nodes: _lakeNodes,
      ways: [..._lakeWays, ...extraWays],
      relations: relations,
    ),
  );
  final dir = Directory(input).parent;
  final output = '${dir.path}/out.pmtiles';

  final report = await const TileBuilder(
    schema: DeliverySchema(minZoom: 12, maxZoom: 14),
  ).build(inputFile: input, outputFile: output, bounds: _bbox);

  return (output, report);
}

/// Decodes the water features from the tile covering the lake.
Future<List<MvtFeature>> _waterAt(String path, int zoom) async {
  final archive = await oracle.PmTilesArchive.fromBytes(
    Uint8List.fromList(File(path).readAsBytesSync()),
    strict: true,
  );
  try {
    final tile = Mercator.tileAt(-48.635, -26.990, zoom);
    final bytes = (await archive.tile(TileId.of(tile))).bytes();
    final decoded = decodeMvtTile(Uint8List.fromList(bytes));
    return [
      for (final layer in decoded.layers)
        if (layer.name == DeliverySchema.waterLayer) ...layer.features,
    ];
  } finally {
    await archive.close();
  }
}

void main() {
  group('multipolygon relations', () {
    test('assembles split members into one water polygon', () async {
      final (path, report) = await _build(relations: [_lakeRelation]);
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      // The relation becomes a feature; its untagged member ways do not.
      expect(report.keptWays, 1);

      final water = await _waterAt(path, 14);
      expect(water, hasLength(1));
      expect(water.single.type, MvtGeomType.polygon);
      expect(water.single.attributes['class'], 'water');
    });

    test('keeps the island as a hole, wound the opposite way', () async {
      final (path, _) = await _build(relations: [_lakeRelation]);
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      final parts = (await _waterAt(path, 14)).single.parts;

      // Exterior ring, then its hole.
      expect(parts, hasLength(2));
      expect(MvtGeometryEncoder.doubledSignedArea(parts[0]), greaterThan(0));
      expect(
        MvtGeometryEncoder.doubledSignedArea(parts[1]),
        lessThan(0),
        reason: 'the island must wind negative or it will not render as a hole',
      );
    });

    test('the hole is smaller than the lake containing it', () async {
      final (path, _) = await _build(relations: [_lakeRelation]);
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      final parts = (await _waterAt(path, 14)).single.parts;
      final outer = MvtGeometryEncoder.doubledSignedArea(parts[0]).abs();
      final inner = MvtGeometryEncoder.doubledSignedArea(parts[1]).abs();
      expect(inner, lessThan(outer));
    });

    test('produces nothing when the outer ring cannot be closed', () async {
      // One half of the boundary is missing, as when a way ran past the
      // extract's own edge. Guessing at a shape not in the data is worse than
      // drawing nothing.
      final broken = const OsmRelation(
        501,
        [OsmMember(100, 'outer')],
        {'type': 'multipolygon', 'natural': 'water'},
      );

      final (path, report) = await _build(relations: [broken]);
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      // No feature, and so no tile — the archive is not opened, because an
      // empty one has an empty directory and strict readers reject it.
      expect(report.keptWays, 0);
      expect(report.tiles, 0);
    });

    test('ignores a relation the schema does not want', () async {
      final route = const OsmRelation(
        502,
        [OsmMember(100, ''), OsmMember(101, '')],
        {'type': 'route', 'route': 'bus'},
      );

      final (path, report) = await _build(relations: [route]);
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      expect(report.keptWays, 0);
    });

    test('still tiles roads alongside the water', () async {
      final (path, report) = await _build(
        extraWays: const [
          OsmWay(200, [1, 3], {'highway': 'primary', 'name': 'Rua da Lagoa'}),
        ],
        relations: [_lakeRelation],
      );
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      expect(report.keptWays, 2);

      final archive = await oracle.PmTilesArchive.fromBytes(
        Uint8List.fromList(File(path).readAsBytesSync()),
        strict: true,
      );
      addTearDown(archive.close);

      final tile = Mercator.tileAt(-48.635, -26.990, 14);
      final decoded = decodeMvtTile(
        Uint8List.fromList((await archive.tile(TileId.of(tile))).bytes()),
      );

      expect({
        for (final l in decoded.layers) l.name,
      }, containsAll([DeliverySchema.roadLayer, DeliverySchema.waterLayer]));
    });
  });

  group('closed ways as areas', () {
    test('turns a closed natural=water way into a polygon', () async {
      final (path, report) = await _build(
        extraWays: const [
          OsmWay(300, [1, 2, 3, 4, 1], {'natural': 'water'}),
        ],
      );
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      expect(report.keptWays, 1);
      final water = await _waterAt(path, 14);
      expect(water.single.type, MvtGeomType.polygon);
      // The repeated closing node is dropped; ClosePath closes the ring.
      expect(
        water.single.parts.single.first,
        isNot(water.single.parts.single.last),
      );
    });

    test('rejects an unclosed way tagged as water', () async {
      // An open way is a riverbank line, not an area.
      final (path, report) = await _build(
        extraWays: const [
          OsmWay(301, [1, 2, 3], {'natural': 'water'}),
        ],
      );
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      expect(report.keptWays, 0);
    });
  });
}
