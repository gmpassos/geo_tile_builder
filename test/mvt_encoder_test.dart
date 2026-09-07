import 'package:geo_tile_builder/geo_tile_builder.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A three-vertex line used across several cases.
const _line = [MvtPoint(0, 0), MvtPoint(1024, 512), MvtPoint(4096, 4096)];

/// An exterior ring: clockwise on screen, which is positive area once Y points
/// down. Right along the top, down the side, back left, up to the origin.
const _square = [
  MvtPoint(0, 0),
  MvtPoint(100, 0),
  MvtPoint(100, 100),
  MvtPoint(0, 100),
];

MvtTile _tileWith(MvtFeature feature, {String layer = 'road'}) => MvtTile(
  layers: [
    MvtLayer(name: layer, features: [feature]),
  ],
);

void main() {
  group('MvtGeometryEncoder', () {
    test('packs a command id and count into one integer', () {
      // MoveTo once: id 1, count 1 -> (1 << 3) | 1 == 9.
      expect(MvtGeometryEncoder.command(1, 1), 9);
      // LineTo twice: id 2, count 2 -> (2 << 3) | 2 == 18.
      expect(MvtGeometryEncoder.command(2, 2), 18);
      // ClosePath once: id 7, count 1 -> (1 << 3) | 7 == 15.
      expect(MvtGeometryEncoder.command(7, 1), 15);
    });

    test('encodes a line as MoveTo(1) then one LineTo for the rest', () {
      final geometry = MvtGeometryEncoder.encode(
        const MvtFeature(type: MvtGeomType.lineString, parts: [_line]),
      );

      expect(geometry.first, MvtGeometryEncoder.command(1, 1));
      // Two remaining vertices ride in a single LineTo.
      expect(geometry[3], MvtGeometryEncoder.command(2, 2));
    });

    test('encodes deltas, not absolute coordinates', () {
      final geometry = MvtGeometryEncoder.encode(
        const MvtFeature(
          type: MvtGeomType.lineString,
          parts: [
            [MvtPoint(10, 10), MvtPoint(15, 10)],
          ],
        ),
      );

      // MoveTo params are absolute (cursor starts at the origin)...
      expect(geometry[1], MvtGeometryEncoder.parameter(10));
      expect(geometry[2], MvtGeometryEncoder.parameter(10));
      // ...and the LineTo param is the +5 step, not 15.
      expect(geometry[4], MvtGeometryEncoder.parameter(5));
      expect(geometry[5], MvtGeometryEncoder.parameter(0));
    });

    test('terminates each polygon ring with ClosePath', () {
      final geometry = MvtGeometryEncoder.encode(
        const MvtFeature(type: MvtGeomType.polygon, parts: [_square]),
      );
      expect(geometry.last, MvtGeometryEncoder.command(7, 1));
    });

    test(
      'drops a repeated closing vertex rather than emitting a zero step',
      () {
        const closed = [..._square, MvtPoint(0, 0)];

        final open = MvtGeometryEncoder.encode(
          const MvtFeature(type: MvtGeomType.polygon, parts: [_square]),
        );
        final explicit = MvtGeometryEncoder.encode(
          const MvtFeature(type: MvtGeomType.polygon, parts: [closed]),
        );

        expect(explicit, open);
      },
    );

    test('drops degenerate parts', () {
      // A single point is not a line, and two points are not a ring.
      expect(
        MvtGeometryEncoder.encode(
          const MvtFeature(
            type: MvtGeomType.lineString,
            parts: [
              [MvtPoint(1, 1)],
            ],
          ),
        ),
        isEmpty,
      );
      expect(
        MvtGeometryEncoder.encode(
          const MvtFeature(
            type: MvtGeomType.polygon,
            parts: [
              [MvtPoint(0, 0), MvtPoint(1, 1)],
            ],
          ),
        ),
        isEmpty,
      );
    });

    test('signs ring area so exterior is positive with Y down', () {
      expect(MvtGeometryEncoder.doubledSignedArea(_square), greaterThan(0));
      expect(
        MvtGeometryEncoder.doubledSignedArea(_square.reversed.toList()),
        lessThan(0),
      );
    });

    test('rejects a delta beyond the parameter range', () {
      expect(
        () => MvtGeometryEncoder.parameter(MvtGeometryEncoder.maxParameter + 1),
        throwsA(isA<MvtGeometryException>()),
      );
    });

    test('refuses geometry of unknown type', () {
      expect(
        () => MvtGeometryEncoder.encode(
          const MvtFeature(type: MvtGeomType.unknown, parts: [_line]),
        ),
        throwsA(isA<MvtGeometryException>()),
      );
    });
  });

  group('MvtEncoder', () {
    const encoder = MvtEncoder();

    test('round-trips a line feature with its attributes', () {
      final tile = _tileWith(
        const MvtFeature(
          id: 42,
          type: MvtGeomType.lineString,
          parts: [_line],
          attributes: {'class': 'primary', 'name': '5ª Avenida'},
        ),
      );

      final decoded = decodeMvtTile(encoder.encode(tile));

      expect(decoded.layers, hasLength(1));
      final layer = decoded.layers.single;
      expect(layer.name, 'road');
      expect(layer.extent, 4096);

      final feature = layer.features.single;
      expect(feature.id, 42);
      expect(feature.type, MvtGeomType.lineString);
      expect(feature.parts, [_line]);
      expect(feature.attributes, {'class': 'primary', 'name': '5ª Avenida'});
    });

    test('round-trips a polygon ring unclosed', () {
      final decoded = decodeMvtTile(
        encoder.encode(
          _tileWith(
            const MvtFeature(type: MvtGeomType.polygon, parts: [_square]),
            layer: 'building',
          ),
        ),
      );

      expect(decoded.layers.single.features.single.parts, [_square]);
    });

    test('round-trips a multipoint as one part', () {
      const points = [MvtPoint(10, 10), MvtPoint(20, 30)];
      final decoded = decodeMvtTile(
        encoder.encode(
          _tileWith(
            const MvtFeature(type: MvtGeomType.point, parts: [points]),
            layer: 'place',
          ),
        ),
      );

      expect(decoded.layers.single.features.single.parts, [points]);
    });

    test('round-trips every supported attribute type', () {
      final decoded = decodeMvtTile(
        encoder.encode(
          _tileWith(
            const MvtFeature(
              type: MvtGeomType.lineString,
              parts: [_line],
              attributes: {
                'text': 'rua',
                'count': 3,
                'ratio': 1.5,
                'bridge': true,
              },
            ),
          ),
        ),
      );

      expect(decoded.layers.single.features.single.attributes, {
        'text': 'rua',
        'count': 3,
        'ratio': 1.5,
        'bridge': true,
      });
    });

    test('dictionary-encodes repeated keys and values once', () {
      // Twenty roads sharing one class must not store that string twenty
      // times — this is the whole reason tiles stay small.
      final many = MvtTile(
        layers: [
          MvtLayer(
            name: 'road',
            features: [
              for (var i = 0; i < 20; i++)
                const MvtFeature(
                  type: MvtGeomType.lineString,
                  parts: [_line],
                  attributes: {'class': 'residential'},
                ),
            ],
          ),
        ],
      );

      final bytes = encoder.encode(many);
      final occurrences = 'residential'.allMatches(String.fromCharCodes(bytes));
      expect(occurrences, hasLength(1));
    });

    test('skips empty layers', () {
      final bytes = encoder.encode(
        const MvtTile(
          layers: [MvtLayer(name: 'road', features: [])],
        ),
      );
      expect(bytes, isEmpty);
    });

    test('skips features whose geometry collapsed', () {
      final decoded = decodeMvtTile(
        encoder.encode(
          _tileWith(
            const MvtFeature(
              type: MvtGeomType.lineString,
              parts: [
                [MvtPoint(0, 0)],
              ],
            ),
          ),
        ),
      );
      expect(decoded.layers, isEmpty);
    });

    test('rejects an unsupported attribute type', () {
      expect(
        () => encoder.encode(
          _tileWith(
            const MvtFeature(
              type: MvtGeomType.lineString,
              parts: [_line],
              attributes: {'when': Duration.zero},
            ),
          ),
        ),
        throwsA(isA<MvtEncodeException>()),
      );
    });

    test('rejects a non-positive extent', () {
      expect(
        () => encoder.encode(
          const MvtTile(
            layers: [
              MvtLayer(
                name: 'road',
                extent: 0,
                features: [
                  MvtFeature(type: MvtGeomType.lineString, parts: [_line]),
                ],
              ),
            ],
          ),
        ),
        throwsA(isA<MvtEncodeException>()),
      );
    });

    test('drops null attribute values instead of encoding them', () {
      final decoded = decodeMvtTile(
        encoder.encode(
          _tileWith(
            const MvtFeature(
              type: MvtGeomType.lineString,
              parts: [_line],
              attributes: {'name': null, 'class': 'track'},
            ),
          ),
        ),
      );

      expect(decoded.layers.single.features.single.attributes, {
        'class': 'track',
      });
    });
  });
}
