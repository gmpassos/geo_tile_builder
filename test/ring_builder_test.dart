import 'package:geo_tile_builder/geo_tile_builder.dart';
import 'package:test/test.dart';

/// A clockwise-on-screen square: positive area with Y down, so exterior.
const _outer = [
  MvtPoint(0, 0),
  MvtPoint(100, 0),
  MvtPoint(100, 100),
  MvtPoint(0, 100),
];

/// A small square inside [_outer].
const _hole = [
  MvtPoint(40, 40),
  MvtPoint(60, 40),
  MvtPoint(60, 60),
  MvtPoint(40, 60),
];

/// A second exterior ring, well clear of the first.
const _outer2 = [
  MvtPoint(200, 0),
  MvtPoint(300, 0),
  MvtPoint(300, 100),
  MvtPoint(200, 100),
];

void main() {
  group('RingBuilder.assemble', () {
    test('closes a ring already given whole', () {
      // First node repeated at the end, as source data usually has it.
      final rings = RingBuilder.assemble([
        [1, 2, 3, 4, 1],
      ]);
      expect(rings, [
        [1, 2, 3, 4],
      ]);
    });

    test('joins fragments given in order', () {
      final rings = RingBuilder.assemble([
        [1, 2],
        [2, 3],
        [3, 4],
        [4, 1],
      ]);
      expect(rings, hasLength(1));
      expect(rings.single, hasLength(4));
      expect(rings.single.toSet(), {1, 2, 3, 4});
    });

    test('joins fragments given out of order', () {
      // The order members appear in a relation means nothing.
      final rings = RingBuilder.assemble([
        [3, 4],
        [1, 2],
        [4, 1],
        [2, 3],
      ]);
      expect(rings, hasLength(1));
      expect(rings.single.toSet(), {1, 2, 3, 4});
    });

    test('reverses a fragment that runs the wrong way', () {
      // [3,2] must be flipped to continue from node 2.
      final rings = RingBuilder.assemble([
        [1, 2],
        [3, 2],
        [3, 4],
        [4, 1],
      ]);
      expect(rings, hasLength(1));
      expect(rings.single.toSet(), {1, 2, 3, 4});
    });

    test('assembles several independent rings', () {
      // Two disjoint triangles, their fragments interleaved.
      final rings = RingBuilder.assemble([
        [1, 2],
        [10, 11, 12],
        [2, 3, 1],
        [12, 10],
      ]);

      expect(rings, hasLength(2));
      expect(
        {for (final r in rings) r.toSet()},
        {
          {1, 2, 3},
          {10, 11, 12},
        },
      );
    });

    test('drops a fragment chain that never closes', () {
      // Routine in a regional extract: the way ran past the boundary.
      expect(
        RingBuilder.assemble([
          [1, 2],
          [2, 3],
        ]),
        isEmpty,
      );
    });

    test('drops degenerate fragments', () {
      expect(
        RingBuilder.assemble([
          [],
          [7],
        ]),
        isEmpty,
      );
    });

    test('drops a ring with too few distinct nodes', () {
      // Two nodes there and back is a line, not an area.
      expect(
        RingBuilder.assemble([
          [1, 2, 1],
        ]),
        isEmpty,
      );
    });

    test('keeps a closed ring and discards an unclosed one alongside it', () {
      final rings = RingBuilder.assemble([
        [1, 2, 3, 1],
        [50, 51],
      ]);
      expect(rings, hasLength(1));
      expect(rings.single.toSet(), {1, 2, 3});
    });
  });

  group('RingBuilder.orient', () {
    test('leaves a correctly wound ring alone', () {
      expect(RingBuilder.orient(_outer, exterior: true), _outer);
    });

    test('reverses a ring wound the wrong way', () {
      final reversed = _outer.reversed.toList();
      expect(RingBuilder.orient(reversed, exterior: true), _outer);
    });

    test('winds a hole negative', () {
      final hole = RingBuilder.orient(_hole, exterior: false);
      expect(MvtGeometryEncoder.doubledSignedArea(hole), lessThan(0));
    });

    test('imposes winding rather than trusting the source', () {
      // Source data respects no convention, so both inputs must come out the
      // same way.
      final fromCw = RingBuilder.orient(_hole, exterior: false);
      final fromCcw = RingBuilder.orient(
        _hole.reversed.toList(),
        exterior: false,
      );
      expect(fromCw, fromCcw);
    });
  });

  group('RingBuilder.containsPoint', () {
    test('accepts a point inside', () {
      expect(RingBuilder.containsPoint(_outer, const MvtPoint(50, 50)), isTrue);
    });

    test('rejects a point outside', () {
      expect(
        RingBuilder.containsPoint(_outer, const MvtPoint(150, 50)),
        isFalse,
      );
      expect(
        RingBuilder.containsPoint(_outer, const MvtPoint(50, -10)),
        isFalse,
      );
    });
  });

  group('RingBuilder.nest', () {
    test('puts a hole directly after its exterior ring', () {
      final parts = RingBuilder.nest([_outer], [_hole]);

      expect(parts, hasLength(2));
      expect(MvtGeometryEncoder.doubledSignedArea(parts[0]), greaterThan(0));
      expect(MvtGeometryEncoder.doubledSignedArea(parts[1]), lessThan(0));
    });

    test('attaches each hole to the ring that actually contains it', () {
      // Two islands; the hole belongs to the first, not the second.
      final parts = RingBuilder.nest([_outer, _outer2], [_hole]);

      expect(parts, hasLength(3));
      expect(parts[0], RingBuilder.orient(_outer, exterior: true));
      expect(MvtGeometryEncoder.doubledSignedArea(parts[1]), lessThan(0));
      // The second island follows, with no hole of its own.
      expect(parts[2], RingBuilder.orient(_outer2, exterior: true));
    });

    test('gives a hole to the smallest ring containing it', () {
      // An island in a lake on an island: the hole belongs to the inner shape,
      // not the outer one, or it punches through the wrong thing.
      const big = [
        MvtPoint(0, 0),
        MvtPoint(400, 0),
        MvtPoint(400, 400),
        MvtPoint(0, 400),
      ];
      final parts = RingBuilder.nest([big, _outer], [_hole]);

      // _outer is the smaller container, so the hole follows it.
      final outerIndex = parts.indexOf(
        RingBuilder.orient(_outer, exterior: true),
      );
      expect(parts[outerIndex + 1].toSet(), _hole.toSet());
    });

    test('drops a hole that lies inside nothing', () {
      const stray = [
        MvtPoint(900, 900),
        MvtPoint(910, 900),
        MvtPoint(910, 910),
      ];
      expect(RingBuilder.nest([_outer], [stray]), hasLength(1));
    });

    test('returns nothing when there is no exterior ring', () {
      expect(RingBuilder.nest(const [], [_hole]), isEmpty);
    });
  });
}
