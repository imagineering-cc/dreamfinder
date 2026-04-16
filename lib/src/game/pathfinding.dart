/// A* pathfinding on a 2D grid with 8-directional movement.
///
/// Designed for the Tech World 50×50 grid. Barriers are stored as a
/// `Set<String>` of `'x,y'` keys for O(1) lookup.
library;

/// A grid cell coordinate.
class GridCell {
  const GridCell(this.x, this.y);

  final int x;
  final int y;

  String get key => '$x,$y';

  @override
  bool operator ==(Object other) =>
      other is GridCell && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'GridCell($x, $y)';
}

/// Direction names matching the Flutter client's Direction enum.
enum Direction {
  up,
  upLeft,
  upRight,
  down,
  downLeft,
  downRight,
  left,
  right,
  none;

  /// JSON value for the data channel protocol.
  String get jsonValue => name;
}

/// 8-directional neighbours with their direction names.
const _neighbours = [
  (dx: 0, dy: -1, dir: Direction.up),
  (dx: 0, dy: 1, dir: Direction.down),
  (dx: -1, dy: 0, dir: Direction.left),
  (dx: 1, dy: 0, dir: Direction.right),
  (dx: -1, dy: -1, dir: Direction.upLeft),
  (dx: 1, dy: -1, dir: Direction.upRight),
  (dx: -1, dy: 1, dir: Direction.downLeft),
  (dx: 1, dy: 1, dir: Direction.downRight),
];

const _cardinalCost = 1.0;
const _diagonalCost = 1.414;

/// Builds a barrier lookup set from coordinate pairs.
Set<String> buildBarrierSet(List<(int, int)> barriers) =>
    {for (final (x, y) in barriers) '$x,$y'};

/// Finds the shortest path from [start] to [goal] using A* with
/// 8-directional movement.
///
/// Returns the path as a list of grid cells (including start and goal),
/// or an empty list if no path exists.
List<GridCell> findPath(
  GridCell start,
  GridCell goal,
  Set<String> barrierSet, {
  int gridSize = 50,
}) {
  if (start == goal) return [start];
  if (barrierSet.contains(goal.key)) return [];

  // Chebyshev distance heuristic (consistent with 8-directional movement).
  int h(GridCell c) {
    final dx = (c.x - goal.x).abs();
    final dy = (c.y - goal.y).abs();
    return dx > dy ? dx : dy;
  }

  final gScore = <String, double>{start.key: 0};
  final fScore = <String, double>{start.key: h(start).toDouble()};
  final cameFrom = <String, String>{};
  final openSet = {start.key};
  final allCells = <String, GridCell>{start.key: start, goal.key: goal};

  while (openSet.isNotEmpty) {
    // Find node in openSet with lowest fScore.
    var currentKey = '';
    var lowestF = double.infinity;
    for (final k in openSet) {
      final f = fScore[k] ?? double.infinity;
      if (f < lowestF) {
        lowestF = f;
        currentKey = k;
      }
    }

    if (currentKey == goal.key) {
      // Reconstruct path.
      final path = <GridCell>[];
      String? traceKey = goal.key;
      while (traceKey != null) {
        path.add(allCells[traceKey]!);
        traceKey = cameFrom[traceKey];
      }
      return path.reversed.toList();
    }

    openSet.remove(currentKey);
    final current = allCells[currentKey]!;
    final currentG = gScore[currentKey]!;

    for (final (:dx, :dy, dir: _) in _neighbours) {
      final nx = current.x + dx;
      final ny = current.y + dy;

      // Bounds check.
      if (nx < 0 || nx >= gridSize || ny < 0 || ny >= gridSize) continue;

      final nKey = '$nx,$ny';
      if (barrierSet.contains(nKey)) continue;

      // For diagonal movement, both adjacent cardinal cells must be clear
      // to prevent cutting corners through barriers.
      if (dx != 0 && dy != 0) {
        if (barrierSet.contains('${current.x + dx},${current.y}') ||
            barrierSet.contains('${current.x},${current.y + dy}')) {
          continue;
        }
      }

      final moveCost = (dx != 0 && dy != 0) ? _diagonalCost : _cardinalCost;
      final tentativeG = currentG + moveCost;

      if (tentativeG < (gScore[nKey] ?? double.infinity)) {
        final neighbour = GridCell(nx, ny);
        allCells[nKey] = neighbour;
        cameFrom[nKey] = currentKey;
        gScore[nKey] = tentativeG;
        fScore[nKey] = tentativeG + h(neighbour);
        openSet.add(nKey);
      }
    }
  }

  // No path found.
  return [];
}

/// Computes the direction for each step along a path of grid cells.
///
/// Returns one fewer direction than [path] length.
List<Direction> pathToDirections(List<GridCell> path) {
  final directions = <Direction>[];
  for (var i = 1; i < path.length; i++) {
    final dx = (path[i].x - path[i - 1].x).sign;
    final dy = (path[i].y - path[i - 1].y).sign;

    var matched = Direction.none;
    for (final n in _neighbours) {
      if (n.dx == dx && n.dy == dy) {
        matched = n.dir;
        break;
      }
    }
    directions.add(matched);
  }
  return directions;
}

/// Converts a path of grid cells to pixel positions.
List<({int x, int y})> pathToPixels(
  List<GridCell> path, {
  required int cellSize,
}) =>
    [for (final c in path) (x: c.x * cellSize, y: c.y * cellSize)];
