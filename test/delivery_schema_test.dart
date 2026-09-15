import 'package:geo_osm_pbf/geo_osm_pbf.dart';
import 'package:geo_tile_builder/geo_tile_builder.dart';
import 'package:test/test.dart';

/// The delivery schema's traffic controls.
///
/// The schema exists to be ruthless — roads, water, and nothing else — so
/// every class admitted here has to earn its place in every tile of every city
/// for ever. The line drawn is **things that stop a vehicle**: a driver plans
/// around a set of lights and does not plan around a street lamp.

const _schema = DeliverySchema();

GeoTaggedNode _node(Map<String, String> tags) =>
    GeoTaggedNode(id: 1, lat: -27.59, lon: -48.55, tags: tags);

void main() {
  group('the signal layer', () {
    test('is declared, so a style has a source-layer to point at', () {
      final ids = {for (final l in _schema.layers) l.id};

      expect(ids, contains(DeliverySchema.signalLayer));
      expect(ids, containsAll(['road', 'water']));
    });

    test('starts late, where a driver could actually stop at one', () {
      // A set of lights is meaningless on a map of a whole city. Carrying them
      // from the schema's own minZoom would push a few thousand points through
      // eight zoom levels that never display one.
      final signals = _schema.layers.firstWhere(
        (l) => l.id == DeliverySchema.signalLayer,
      );

      // The number, not just the constant compared against itself — lowering
      // it is a size decision and should have to be made here too.
      expect(DeliverySchema.signalMinZoom, equals(14));
      expect(signals.minZoom, equals(DeliverySchema.signalMinZoom));
      expect(signals.minZoom, greaterThan(_schema.minZoom));
      expect(signals.maxZoom, equals(_schema.maxZoom));
    });

    test('declares the `class` a style switches on', () {
      // The contract with `MapPackStore.styleJsonFor`, which paints by
      // `['get', 'class']`. A layer that stopped carrying it would render one
      // flat colour and nothing would say so.
      final signals = _schema.layers.firstWhere(
        (l) => l.id == DeliverySchema.signalLayer,
      );

      expect(signals.toMetadata()['fields'], contains('class'));
    });

    test('disappears entirely when signals are off', () {
      const off = DeliverySchema(includeSignals: false);

      expect({
        for (final l in off.layers) l.id,
      }, isNot(contains(DeliverySchema.signalLayer)));
      expect(off.node(_node({'highway': 'traffic_signals'})), isNull);
    });
  });

  group('reading nodes at all', () {
    test('is what carrying signals costs, and it is declared', () {
      // Node tags live in a packed stream a reader can otherwise skip whole.
      // Saying yes means decoding tens of millions of entries that are almost
      // all untagged shape points — so the flag has to follow the option.
      expect(_schema.readsNodes, isTrue);
      expect(const DeliverySchema(includeSignals: false).readsNodes, isFalse);
    });
  });

  group('what counts as a control', () {
    test('traffic lights, which are the point of the exercise', () {
      final signal = _schema.node(_node({'highway': 'traffic_signals'}))!;

      expect(signal.layer, equals(DeliverySchema.signalLayer));
      expect(signal.type, equals(MvtGeomType.point));
      expect(signal.attributes['class'], equals('traffic_signals'));
    });

    test('stop and give-way signs', () {
      expect(
        _schema.node(_node({'highway': 'stop'}))!.attributes['class'],
        equals('stop'),
      );
      expect(
        _schema.node(_node({'highway': 'give_way'}))!.attributes['class'],
        equals('give_way'),
      );
    });

    test('level crossings, the one that holds a rider for minutes', () {
      // Tagged on the railway rather than the highway, which is why it is
      // looked for first.
      expect(
        _schema.node(_node({'railway': 'level_crossing'}))!.attributes['class'],
        equals('level_crossing'),
      );
    });

    test('a railway crossing wins over whatever else the node is', () {
      // A level crossing is routinely also tagged as a highway crossing, and
      // sometimes carries `crossing=traffic_signals` for its own lights. It is
      // the more consequential of the two — minutes rather than seconds — so
      // the railway tag is read first, and this pins that order.
      expect(
        _schema
            .node(
              _node({
                'railway': 'level_crossing',
                'highway': 'crossing',
                'crossing': 'traffic_signals',
              }),
            )!
            .attributes['class'],
        equals('level_crossing'),
      );
    });

    test('a crossing tag alone is not a junction', () {
      // `crossing=traffic_signals` describes *how* a crossing works. Without
      // `highway=crossing` there is no crossing for it to describe, and
      // matching on it alone would pick up stray tagging.
      expect(_schema.node(_node({'crossing': 'traffic_signals'})), isNull);
    });

    test('lights stay lights whatever else is on the node', () {
      // Junction nodes accumulate tags — a name, a direction, an operator.
      // None of them change what it is.
      expect(
        _schema
            .node(
              _node({
                'highway': 'traffic_signals',
                'traffic_signals:direction': 'forward',
                'name': 'Cruzamento Central',
              }),
            )!
            .attributes['class'],
        equals('traffic_signals'),
      );
    });

    test('and a signalised pedestrian crossing, which is a set of lights', () {
      // Tagged as a crossing, not as `highway=traffic_signals`. Missing this
      // would drop real lights along with the plain crossings below.
      final signalised = _schema.node(
        _node({'highway': 'crossing', 'crossing': 'traffic_signals'}),
      )!;

      expect(signalised.attributes['class'], equals('traffic_signals'));

      expect(
        _schema
            .node(_node({'highway': 'crossing', 'crossing:signals': 'yes'}))!
            .attributes['class'],
        equals('traffic_signals'),
      );
    });
  });

  group('what does not', () {
    test('a plain pedestrian crossing, of which there are several a block', () {
      // The exclusion that keeps this layer readable. Unsignalised crossings
      // would outnumber every other control by an order of magnitude and mean
      // nothing to a driver at speed.
      expect(_schema.node(_node({'highway': 'crossing'})), isNull);
      expect(
        _schema.node(_node({'highway': 'crossing', 'crossing': 'zebra'})),
        isNull,
      );
    });

    test('street furniture, and anything else a driver ignores', () {
      for (final tags in [
        {'highway': 'street_lamp'},
        {'highway': 'bus_stop'},
        {'highway': 'speed_camera'},
        {'highway': 'turning_circle'},
        {'amenity': 'cafe', 'name': 'Café'},
        {'place': 'city', 'name': 'Florianópolis'},
        {'barrier': 'gate'},
      ]) {
        expect(
          _schema.node(_node(tags)),
          isNull,
          reason: '$tags is not something a vehicle stops at',
        );
      }
    });

    test('an untagged road junction', () {
      // Most nodes in an extract are shape points. They never reach `node`,
      // but nothing about the classification should depend on that.
      expect(_schema.node(_node(const {})), isNull);
    });
  });
}
