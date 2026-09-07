import 'dart:io';
import 'dart:typed_data';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';
import 'package:geo_tile_builder/geo_tile_builder.dart';
import 'package:pmtiles/pmtiles.dart' as oracle;
import 'package:test/test.dart';

import 'support.dart';

/// A few blocks of Balneário Camboriú.
const _bbox = OsmBoundingBox(
  minLon: -48.66,
  minLat: -27.01,
  maxLon: -48.61,
  maxLat: -26.97,
);

/// A north–south avenue and an east–west cross street meeting in the middle.
final _nodes = [
  const OsmNode(1, -27.005, -48.635),
  const OsmNode(2, -26.995, -48.635),
  const OsmNode(3, -26.985, -48.635),
  const OsmNode(4, -26.995, -48.645),
  const OsmNode(5, -26.995, -48.625),
  // A residential street, only drawn at high zoom.
  const OsmNode(6, -26.990, -48.640),
  const OsmNode(7, -26.990, -48.630),
];

final _ways = [
  const OsmWay(
    100,
    [1, 2, 3],
    {'highway': 'primary', 'name': 'Avenida Atlântica'},
  ),
  const OsmWay(101, [4, 2, 5], {'highway': 'secondary', 'name': 'Rua 1500'}),
  const OsmWay(102, [6, 7], {'highway': 'residential', 'name': 'Rua Pequena'}),
  // Neither of these should survive the schema.
  const OsmWay(103, [1, 3], {'barrier': 'fence'}),
  const OsmWay(104, [4, 5], {'highway': 'proposed'}),
];

String _writeExtract() =>
    writeTempOsmPbf(buildOsmPbf(nodes: _nodes, ways: _ways));

/// Builds an archive from the synthetic extract and returns its path.
Future<(String, TileBuildReport)> _build({
  TileSchema schema = const DeliverySchema(minZoom: 10, maxZoom: 14),
}) async {
  final input = _writeExtract();
  final dir = Directory(input).parent;
  final output = '${dir.path}/out.pmtiles';

  final report = await TileBuilder(
    schema: schema,
  ).build(inputFile: input, outputFile: output, bounds: _bbox);

  return (output, report);
}

void main() {
  group('DeliverySchema', () {
    const schema = DeliverySchema();

    test('classifies roads by weight and assigns each a minimum zoom', () {
      final motorway = schema.way(
        const GeoWay(id: 1, nodeIds: [1, 2], tags: {'highway': 'motorway'}),
      );
      expect(motorway!.layer, DeliverySchema.roadLayer);
      expect(motorway.attributes['class'], 'motorway');
      expect(motorway.minZoom, 6);

      final residential = schema.way(
        const GeoWay(id: 2, nodeIds: [1, 2], tags: {'highway': 'residential'}),
      );
      // A side street has no business existing above z13.
      expect(residential!.attributes['class'], 'minor');
      expect(residential.minZoom, 13);
    });

    test('collapses the link variants onto their parent class', () {
      final link = schema.way(
        const GeoWay(id: 1, nodeIds: [1, 2], tags: {'highway': 'primary_link'}),
      );
      expect(link!.attributes['class'], 'primary');
    });

    test('drops everything it has no use for', () {
      for (final tags in [
        {'barrier': 'fence'},
        {'building': 'yes'},
        {'landuse': 'residential'},
        {'highway': 'proposed'},
        <String, String>{},
      ]) {
        expect(
          schema.way(GeoWay(id: 1, nodeIds: const [1, 2], tags: tags)),
          isNull,
          reason: '$tags',
        );
      }
    });

    test('drops a way too short to be a line', () {
      expect(
        schema.way(
          const GeoWay(id: 1, nodeIds: [1], tags: {'highway': 'primary'}),
        ),
        isNull,
      );
    });

    test('carries a name only when asked to', () {
      const tags = {'highway': 'primary', 'name': 'Avenida Atlântica'};
      expect(
        schema
            .way(const GeoWay(id: 1, nodeIds: [1, 2], tags: tags))!
            .attributes['name'],
        'Avenida Atlântica',
      );
      expect(
        const DeliverySchema(includeNames: false)
            .way(const GeoWay(id: 1, nodeIds: [1, 2], tags: tags))!
            .attributes
            .containsKey('name'),
        isFalse,
      );
    });

    test('emits no features for nodes', () {
      // No POIs and no place labels is a large part of why the tiles are small.
      expect(
        schema.node(
          const GeoTaggedNode(
            id: 1,
            lat: 0,
            lon: 0,
            tags: {'place': 'city', 'name': 'Santos'},
          ),
        ),
        isNull,
      );
    });

    test('ranks heavier roads above lighter ones', () {
      int rank(String highway) => schema
          .way(
            GeoWay(id: 1, nodeIds: const [1, 2], tags: {'highway': highway}),
          )!
          .sortRank;
      expect(rank('motorway'), greaterThan(rank('primary')));
      expect(rank('primary'), greaterThan(rank('residential')));
    });

    test('declares its layers for the archive metadata', () {
      final ids = [for (final l in schema.layers) l.id];
      expect(
        ids,
        containsAll([DeliverySchema.roadLayer, DeliverySchema.waterLayer]),
      );
      final road = schema.layers.firstWhere((l) => l.id == 'road');
      expect(road.toMetadata()['fields'], contains('class'));
    });
  });

  group('NodeStore', () {
    test('keeps only the ids it was asked for', () {
      final collector = NodeIdCollector()..addAll([5, 1, 5, 3, 1]);
      final store = NodeStore(collector.sortedUnique());

      // Duplicates collapse; the table is the distinct set.
      expect(store.length, 3);
      expect(store.wants(1), isTrue);
      expect(store.wants(4), isFalse);
    });

    test('round-trips coordinates to about a centimetre', () {
      final store = NodeStore((NodeIdCollector()..add(42)).sortedUnique());
      expect(store.set(42, -26.9906, -48.6353), isTrue);

      final (lon, lat) = store.coordinateOf(42)!;
      expect(lat, closeTo(-26.9906, 1e-7));
      expect(lon, closeTo(-48.6353, 1e-7));
    });

    test('ignores coordinates for ids it does not track', () {
      final store = NodeStore((NodeIdCollector()..add(1)).sortedUnique());
      expect(store.set(999, 1, 1), isFalse);
      expect(store.coordinateOf(999), isNull);
    });

    test('reports an unresolved id as null, not as zero', () {
      // A regional extract routinely references nodes it does not contain, and
      // reading those back as (0, 0) would draw roads to null island.
      final store = NodeStore((NodeIdCollector()..add(7)).sortedUnique());
      expect(store.coordinateOf(7), isNull);
      expect(store.filled, 0);
    });

    test('stays flat: sixteen bytes per node', () {
      final collector = NodeIdCollector();
      for (var i = 0; i < 1000; i++) {
        collector.add(i);
      }
      final store = NodeStore(collector.sortedUnique());
      expect(store.byteSize, 1000 * 16);
    });

    test('grows past its initial buffer', () {
      final collector = NodeIdCollector();
      for (var i = 0; i < 5000; i++) {
        collector.add(i);
      }
      expect(collector.sortedUnique().length, 5000);
    });

    test('handles an empty collector', () {
      expect(NodeIdCollector().sortedUnique(), isEmpty);
    });
  });

  group('TileBuilder', () {
    test('turns an extract into a readable archive', () async {
      final (path, report) = await _build();
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      // Three roads kept; the fence and the proposed road dropped.
      expect(report.keptWays, 3);
      expect(report.resolvedNodes, report.referencedNodes);
      expect(report.tiles, greaterThan(0));

      final archive = await oracle.PmTilesArchive.fromBytes(
        Uint8List.fromList(File(path).readAsBytesSync()),
        strict: true,
      );
      addTearDown(archive.close);

      final metadata = await archive.metadata as Map<String, Object?>;
      expect(metadata['name'], 'delivery');
      expect(metadata['vector_layers'], hasLength(2));
    });

    test('places roads in the tile that actually contains them', () async {
      final (path, _) = await _build();
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      final archive = await oracle.PmTilesArchive.fromBytes(
        Uint8List.fromList(File(path).readAsBytesSync()),
        strict: true,
      );
      addTearDown(archive.close);

      // The tile covering the junction of the two named roads.
      final tile = Mercator.tileAt(-48.635, -26.995, 14);
      final bytes = (await archive.tile(TileId.of(tile))).bytes();
      final decoded = decodeMvtTile(Uint8List.fromList(bytes));

      final road = decoded.layers.firstWhere((l) => l.name == 'road');
      final names = {for (final f in road.features) f.attributes['name']};
      expect(names, containsAll(['Avenida Atlântica', 'Rua 1500']));
    });

    test('honours per-feature minimum zoom', () async {
      final (path, _) = await _build();
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      final archive = await oracle.PmTilesArchive.fromBytes(
        Uint8List.fromList(File(path).readAsBytesSync()),
        strict: true,
      );
      addTearDown(archive.close);

      Future<Set<Object?>> classesAt(int zoom) async {
        final tile = Mercator.tileAt(-48.635, -26.990, zoom);
        final bytes = (await archive.tile(TileId.of(tile))).bytes();
        final decoded = decodeMvtTile(Uint8List.fromList(bytes));
        final road = decoded.layers.where((l) => l.name == 'road');
        return {
          for (final l in road)
            for (final f in l.features) f.attributes['class'],
        };
      }

      // The residential street earns its place only at z13.
      expect(await classesAt(12), isNot(contains('minor')));
      expect(await classesAt(13), contains('minor'));
    });

    test('clips a road into every tile it crosses', () async {
      final (path, report) = await _build();
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      // The avenue spans more than one z14 tile, so it is written more than
      // once — features are counted per tile they appear in.
      expect(report.features, greaterThan(report.keptWays));
    });

    test('restricts output to the given bounds', () async {
      final input = _writeExtract();
      final dir = Directory(input).parent;
      addTearDown(() => dir.deleteSync(recursive: true));

      // A service area covering none of the geometry.
      final report =
          await const TileBuilder(
            schema: DeliverySchema(minZoom: 12, maxZoom: 14),
          ).build(
            inputFile: input,
            outputFile: '${dir.path}/empty.pmtiles',
            bounds: const OsmBoundingBox(
              minLon: -40.0,
              minLat: -20.0,
              maxLon: -39.9,
              maxLat: -19.9,
            ),
          );

      expect(report.keptWays, 3);
      expect(report.tiles, 0);
    });

    test('falls back to the extract bounding box', () async {
      final input = _writeExtract();
      final dir = Directory(input).parent;
      addTearDown(() => dir.deleteSync(recursive: true));

      // No `bounds`: the header's own bbox must be used.
      final report = await const TileBuilder(
        schema: DeliverySchema(minZoom: 12, maxZoom: 13),
      ).build(inputFile: input, outputFile: '${dir.path}/auto.pmtiles');

      expect(report.tiles, greaterThan(0));
    });

    test('reports the zoom range it built', () async {
      final (path, report) = await _build(
        schema: const DeliverySchema(minZoom: 11, maxZoom: 13),
      );
      addTearDown(() => File(path).parent.deleteSync(recursive: true));

      expect(report.minZoom, 11);
      expect(report.maxZoom, 13);
      final header = PmTilesHeader.fromBytes(
        Uint8List.fromList(File(path).readAsBytesSync()),
      );
      expect(header.minZoom, greaterThanOrEqualTo(11));
      expect(header.maxZoom, lessThanOrEqualTo(13));
    });
  });
}
