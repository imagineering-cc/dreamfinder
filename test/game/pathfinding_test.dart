import 'package:dreamfinder/src/game/pathfinding.dart';
import 'package:test/test.dart';

void main() {
  group('buildBarrierSet', () {
    test('creates set from coordinate pairs', () {
      final barriers = buildBarrierSet([(2, 3), (5, 10)]);

      expect(barriers, contains('2,3'));
      expect(barriers, contains('5,10'));
      expect(barriers, hasLength(2));
    });

    test('returns empty set for empty input', () {
      expect(buildBarrierSet([]), isEmpty);
    });
  });

  group('findPath', () {
    test('returns single-cell path when start equals goal', () {
      final path = findPath(
        const GridCell(5, 5),
        const GridCell(5, 5),
        <String>{},
      );

      expect(path, hasLength(1));
      expect(path.first, const GridCell(5, 5));
    });

    test('finds straight horizontal path on empty grid', () {
      final path = findPath(
        const GridCell(0, 0),
        const GridCell(3, 0),
        <String>{},
      );

      expect(path, isNotEmpty);
      expect(path.first, const GridCell(0, 0));
      expect(path.last, const GridCell(3, 0));
      // Straight line: 4 cells (start + 3 steps)
      expect(path, hasLength(4));
    });

    test('finds straight vertical path on empty grid', () {
      final path = findPath(
        const GridCell(0, 0),
        const GridCell(0, 3),
        <String>{},
      );

      expect(path, isNotEmpty);
      expect(path.first, const GridCell(0, 0));
      expect(path.last, const GridCell(0, 3));
    });

    test('finds diagonal path on empty grid', () {
      final path = findPath(
        const GridCell(0, 0),
        const GridCell(3, 3),
        <String>{},
      );

      expect(path, isNotEmpty);
      expect(path.first, const GridCell(0, 0));
      expect(path.last, const GridCell(3, 3));
      // Pure diagonal: 4 cells
      expect(path, hasLength(4));
    });

    test('navigates around a barrier', () {
      // Barrier blocks the direct path at (1, 0)
      final barriers = buildBarrierSet([(1, 0)]);

      final path = findPath(
        const GridCell(0, 0),
        const GridCell(2, 0),
        barriers,
      );

      expect(path, isNotEmpty);
      expect(path.first, const GridCell(0, 0));
      expect(path.last, const GridCell(2, 0));
      // Path should not pass through (1, 0)
      expect(path, isNot(contains(const GridCell(1, 0))));
    });

    test('returns empty path when goal is blocked', () {
      final barriers = buildBarrierSet([(5, 5)]);

      final path = findPath(
        const GridCell(0, 0),
        const GridCell(5, 5),
        barriers,
      );

      expect(path, isEmpty);
    });

    test('returns empty path when completely surrounded', () {
      // Surround the start cell with barriers
      final barriers = buildBarrierSet([
        (0, 1),
        (1, 0),
        (1, 1),
      ]);

      final path = findPath(
        const GridCell(0, 0),
        const GridCell(5, 5),
        barriers,
      );

      expect(path, isEmpty);
    });

    test('respects grid boundaries', () {
      final path = findPath(
        const GridCell(0, 0),
        const GridCell(49, 49),
        <String>{},
      );

      expect(path, isNotEmpty);
      expect(path.first, const GridCell(0, 0));
      expect(path.last, const GridCell(49, 49));

      // All cells must be within bounds
      for (final cell in path) {
        expect(cell.x, inInclusiveRange(0, 49));
        expect(cell.y, inInclusiveRange(0, 49));
      }
    });

    test('prevents diagonal corner-cutting through barriers', () {
      // Place barriers at (1, 0) and (0, 1) — moving diagonally to (1, 1)
      // should NOT cut the corner between them.
      final barriers = buildBarrierSet([(1, 0), (0, 1)]);

      final path = findPath(
        const GridCell(0, 0),
        const GridCell(1, 1),
        barriers,
      );

      // Either empty (fully blocked) or takes a longer path
      // With both cardinal neighbours blocked, diagonal is forbidden
      expect(path, isEmpty);
    });

    test('allows diagonal when only one adjacent cardinal is blocked', () {
      // Only (1, 0) is blocked — can still reach (1, 1) via (0, 1) then (1, 1)
      final barriers = buildBarrierSet([(1, 0)]);

      final path = findPath(
        const GridCell(0, 0),
        const GridCell(1, 1),
        barriers,
      );

      expect(path, isNotEmpty);
      expect(path.last, const GridCell(1, 1));
    });

    test('uses custom grid size', () {
      // Goal is outside a 5×5 grid — should fail
      final path = findPath(
        const GridCell(0, 0),
        const GridCell(10, 10),
        <String>{},
        gridSize: 5,
      );

      expect(path, isEmpty);
    });
  });

  group('pathToDirections', () {
    test('returns empty for single-cell path', () {
      final directions = pathToDirections([const GridCell(5, 5)]);
      expect(directions, isEmpty);
    });

    test('computes cardinal directions', () {
      final path = [
        const GridCell(0, 0),
        const GridCell(1, 0),
        const GridCell(1, 1),
      ];
      final directions = pathToDirections(path);

      expect(directions, [Direction.right, Direction.down]);
    });

    test('computes diagonal directions', () {
      final path = [
        const GridCell(0, 0),
        const GridCell(1, 1),
        const GridCell(0, 2),
      ];
      final directions = pathToDirections(path);

      expect(directions, [Direction.downRight, Direction.downLeft]);
    });

    test('returns one fewer direction than path length', () {
      final path = [
        const GridCell(0, 0),
        const GridCell(1, 0),
        const GridCell(2, 0),
        const GridCell(3, 0),
      ];
      final directions = pathToDirections(path);

      expect(directions, hasLength(3));
    });
  });

  group('pathToPixels', () {
    test('converts grid cells to pixel positions', () {
      final path = [
        const GridCell(0, 0),
        const GridCell(1, 2),
        const GridCell(3, 4),
      ];
      final pixels = pathToPixels(path, cellSize: 32);

      expect(pixels, [
        (x: 0, y: 0),
        (x: 32, y: 64),
        (x: 96, y: 128),
      ]);
    });

    test('returns empty for empty path', () {
      expect(pathToPixels([], cellSize: 16), isEmpty);
    });
  });

  group('GridCell', () {
    test('equality works by value', () {
      expect(const GridCell(3, 7), const GridCell(3, 7));
      expect(const GridCell(3, 7), isNot(const GridCell(7, 3)));
    });

    test('hashCode is consistent with equality', () {
      expect(const GridCell(3, 7).hashCode, const GridCell(3, 7).hashCode);
    });

    test('toString is readable', () {
      expect(const GridCell(3, 7).toString(), 'GridCell(3, 7)');
    });
  });
}
