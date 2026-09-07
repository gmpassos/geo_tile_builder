import 'dart:io';
import 'dart:typed_data';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';
import 'package:geo_tile_builder/geo_tile_builder.dart';
import 'package:pmtiles/pmtiles.dart' as oracle;
import 'package:test/test.dart';

import 'support.dart';

const _schema = OpenMapTilesSchema();

GeoWay _way(Map<String, String> tags, {List<int> nodes = const [1, 2]}) =>
    GeoWay(id: 1, nodeIds: nodes, tags: tags);

GeoTaggedNode _node(Map<String, String> tags) =>
    GeoTaggedNode(id: 1, lat: -26.99, lon: -48.63, tags: tags);

void main() {
  group('OpenMapTilesSchema layers', () {
    test('uses the schema\'s own layer names, so styles just work', () {
      final ids = {for (final l in _schema.layers) l.id};
      expect(ids, {
        'transportation',
        'transportation_name',
        'water',
        'waterway',
        'building',
        'place',
      });
    });

    test('can leave buildings out', () {
      final ids = {
        for (final l in const OpenMapTilesSchema(
          includeBuildings: false,
        ).layers)
          l.id,
      };
      expect(ids, isNot(contains('building')));
    });
  });

  group('OpenMapTilesSchema roads', () {
    test('maps highways onto transportation classes', () {
      expect(
        _schema.way(_way({'highway': 'motorway'}))!.attributes['class'],
        'motorway',
      );
      expect(
        _schema.way(_way({'highway': 'residential'}))!.attributes['class'],
        'minor',
      );
    });

    test('gives a link ramp its parent class and keeps the subclass', () {
      final link = _schema.way(_way({'highway': 'motorway_link'}))!;
      expect(link.attributes['class'], 'motorway');
      expect(link.attributes['subclass'], isNull);

      final path = _schema.way(_way({'highway': 'footway'}))!;
      expect(path.attributes['class'], 'path');
      // The specific kind survives where it differs from the class.
      expect(path.attributes['subclass'], 'footway');
    });

    test('collapses bridges and tunnels into brunnel', () {
      expect(
        _schema
            .way(_way({'highway': 'primary', 'bridge': 'yes'}))!
            .attributes['brunnel'],
        'bridge',
      );
      expect(
        _schema
            .way(_way({'highway': 'primary', 'tunnel': 'yes'}))!
            .attributes['brunnel'],
        'tunnel',
      );
      // `no` is not a brunnel.
      expect(
        _schema
            .way(_way({'highway': 'primary', 'bridge': 'no'}))!
            .attributes
            .containsKey('brunnel'),
        isFalse,
      );
    });

    test('flags one-way streets', () {
      expect(
        _schema
            .way(_way({'highway': 'primary', 'oneway': 'yes'}))!
            .attributes['oneway'],
        1,
      );
      expect(
        _schema
            .way(_way({'highway': 'primary'}))!
            .attributes
            .containsKey('oneway'),
        isFalse,
      );
    });

    test('starts big roads at low zoom and small ones late', () {
      expect(_schema.way(_way({'highway': 'motorway'}))!.minZoom, 4);
      expect(_schema.way(_way({'highway': 'residential'}))!.minZoom, 12);
      expect(_schema.way(_way({'highway': 'footway'}))!.minZoom, 14);
    });
  });

  group('OpenMapTilesSchema areas', () {
    const ring = [1, 2, 3, 4, 1];

    test('turns a closed water way into a lake polygon', () {
      final water = _schema.way(_way({'natural': 'water'}, nodes: ring))!;
      expect(water.layer, 'water');
      expect(water.type, MvtGeomType.polygon);
      expect(water.attributes['class'], 'lake');
    });

    test('ignores an unclosed water way', () {
      expect(_schema.way(_way({'natural': 'water'})), isNull);
    });

    test('emits buildings with a height when one can be worked out', () {
      final fromHeight = _schema.way(
        _way({'building': 'yes', 'height': '12.5'}, nodes: ring),
      )!;
      expect(fromHeight.layer, 'building');
      expect(fromHeight.attributes['render_height'], 12.5);

      // Levels are the usual fallback, at the conventional storey height.
      final fromLevels = _schema.way(
        _way({'building': 'yes', 'building:levels': '3'}, nodes: ring),
      )!;
      expect(fromLevels.attributes['render_height'], closeTo(10.98, 0.01));

      // No height at all is fine; the field is simply absent.
      final plain = _schema.way(_way({'building': 'yes'}, nodes: ring))!;
      expect(plain.attributes.containsKey('render_height'), isFalse);
    });

    test('emits waterways as lines', () {
      final river = _schema.way(
        _way({'waterway': 'river', 'name': 'Rio Camboriú'}),
      )!;
      expect(river.layer, 'waterway');
      expect(river.type, MvtGeomType.lineString);
      expect(river.attributes['name'], 'Rio Camboriú');
      expect(river.minZoom, 9);
      // A ditch is not worth carrying as early as a river.
      expect(_schema.way(_way({'waterway': 'ditch'}))!.minZoom, 12);
    });

    test('keeps a water multipolygon', () {
      final relation = _schema.relation(
        const GeoRelation(
          id: 1,
          members: [],
          tags: {'type': 'multipolygon', 'natural': 'water'},
        ),
      );
      expect(relation!.layer, 'water');
    });
  });

  group('OpenMapTilesSchema places', () {
    test('reads nodes, unlike the delivery schema', () {
      expect(_schema.readsNodes, isTrue);
      expect(const DeliverySchema().readsNodes, isFalse);
    });

    test('ranks settlements so labels can be prioritised', () {
      final city = _schema.node(_node({'place': 'city', 'name': 'Itajaí'}))!;
      final village = _schema.node(
        _node({'place': 'village', 'name': 'Estaleiro'}),
      )!;

      expect(city.layer, 'place');
      expect(city.type, MvtGeomType.point);
      expect(
        city.attributes['rank'],
        lessThan(village.attributes['rank']! as int),
      );
      // And the smaller place appears later.
      expect(city.minZoom, lessThan(village.minZoom));
    });

    test('drops a place with no name, which cannot be labelled', () {
      expect(_schema.node(_node({'place': 'city'})), isNull);
    });

    test('drops a tagged node that is not a place', () {
      expect(_schema.node(_node({'amenity': 'cafe', 'name': 'Bar'})), isNull);
    });
  });

  group('point features end to end', () {
    test('a place node reaches the tile it sits in', () async {
      final input = writeTempOsmPbf(
        buildOsmPbf(
          nodes: const [
            OsmNode(1, -26.995, -48.640),
            OsmNode(2, -26.985, -48.630),
            // The labelled place itself.
            OsmNode(9, -26.990, -48.635),
          ],
          taggedNodes: const {
            9: {'place': 'town', 'name': 'Balneário Camboriú'},
          },
          ways: const [
            OsmWay(100, [1, 2], {'highway': 'primary'}),
          ],
        ),
      );
      final dir = Directory(input).parent;
      addTearDown(() => dir.deleteSync(recursive: true));
      final output = '${dir.path}/omt.pmtiles';

      await const TileBuilder(
        schema: OpenMapTilesSchema(minZoom: 12, maxZoom: 14),
      ).build(
        inputFile: input,
        outputFile: output,
        bounds: const OsmBoundingBox(
          minLon: -48.66,
          minLat: -27.01,
          maxLon: -48.61,
          maxLat: -26.97,
        ),
      );

      final archive = await oracle.PmTilesArchive.fromBytes(
        Uint8List.fromList(File(output).readAsBytesSync()),
        strict: true,
      );
      addTearDown(archive.close);

      final tile = Mercator.tileAt(-48.635, -26.990, 14);
      final decoded = decodeMvtTile(
        Uint8List.fromList((await archive.tile(TileId.of(tile))).bytes()),
      );

      final place = decoded.layers.firstWhere((l) => l.name == 'place');
      expect(place.features.single.type, MvtGeomType.point);
      expect(place.features.single.attributes['name'], 'Balneário Camboriú');
      // A point is one part holding one vertex.
      expect(place.features.single.parts.single, hasLength(1));
    });
  });
}
