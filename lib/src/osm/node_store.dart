import 'dart:typed_data';

/// Collects the node ids a pass over ways asked for.
///
/// A growable typed buffer rather than a `Set<int>`: the ids arrive with heavy
/// duplication (every shared junction is referenced by each way that meets
/// there), and sorting once at the end is far cheaper in both time and memory
/// than hashing tens of millions of boxed integers along the way.
class NodeIdCollector {
  Int64List _ids = Int64List(1024);
  int _length = 0;

  /// Ids recorded so far, including duplicates.
  int get length => _length;

  void add(int id) {
    if (_length == _ids.length) _grow();
    _ids[_length++] = id;
  }

  void addAll(Iterable<int> ids) {
    for (final id in ids) {
      add(id);
    }
  }

  void _grow() {
    final grown = Int64List(_ids.length * 2);
    grown.setRange(0, _ids.length, _ids);
    _ids = grown;
  }

  /// Sorts and deduplicates into the lookup table a [NodeStore] is built on.
  Int64List sortedUnique() {
    if (_length == 0) return Int64List(0);

    final view = Int64List.sublistView(_ids, 0, _length)..sort();

    var unique = 1;
    for (var i = 1; i < view.length; i++) {
      if (view[i] != view[unique - 1]) view[unique++] = view[i];
    }

    return Int64List.sublistView(view, 0, unique);
  }
}

/// Node coordinates for a known set of ids, held in flat typed arrays.
///
/// This is the piece that decides whether a region-sized extract fits in
/// memory. The obvious `Map<int, GeoNode>` costs a boxed key, a boxed object
/// and a hash entry per node — well over a hundred bytes. Here it is 16: eight
/// for the sorted id and four each for latitude and longitude, stored as
/// integers in units of 1e-7 degrees, which is about a centimetre and far finer
/// than any map needs.
///
/// Lookup is a binary search over the sorted ids rather than a hash, which is a
/// few nanoseconds slower per node and saves the entire hash table.
class NodeStore {
  /// Sorted, unique node ids this store has room for.
  final Int64List _ids;

  /// Latitude and longitude in 1e-7 degrees, or [_unset].
  final Int32List _lat;
  final Int32List _lon;

  /// Sentinel for "not filled in yet".
  ///
  /// Safe because valid latitudes reach only ±900,000,000 in these units, so
  /// no real coordinate can collide with it.
  static const int _unset = -2147483648;

  NodeStore._(this._ids)
    : _lat = Int32List(_ids.length)..fillRange(0, _ids.length, _unset),
      _lon = Int32List(_ids.length);

  /// Creates a store for [sortedUniqueIds], which must be ascending and free
  /// of duplicates — [NodeIdCollector.sortedUnique] produces exactly that.
  factory NodeStore(Int64List sortedUniqueIds) => NodeStore._(sortedUniqueIds);

  /// Number of node ids this store tracks.
  int get length => _ids.length;

  /// Number of ids whose coordinates have been filled in.
  int get filled {
    var count = 0;
    for (var i = 0; i < _lat.length; i++) {
      if (_lat[i] != _unset) count++;
    }
    return count;
  }

  /// Whether [id] is one of the ids this store is collecting.
  bool wants(int id) => _indexOf(id) >= 0;

  /// Records a coordinate, ignoring ids the store is not collecting.
  ///
  /// Returns whether it was kept, so a caller can count what it dropped.
  bool set(int id, double lat, double lon) {
    final i = _indexOf(id);
    if (i < 0) return false;
    _lat[i] = (lat / 1e-7).round();
    _lon[i] = (lon / 1e-7).round();
    return true;
  }

  /// The coordinate recorded for [id] as `(lon, lat)`, or null if the id is
  /// unknown or was never filled in.
  ///
  /// A missing coordinate is normal, not an error: a regional extract routinely
  /// contains ways whose nodes lie outside its own boundary.
  (double, double)? coordinateOf(int id) {
    final i = _indexOf(id);
    if (i < 0 || _lat[i] == _unset) return null;
    return (_lon[i] * 1e-7, _lat[i] * 1e-7);
  }

  /// Binary search for [id], or -1.
  int _indexOf(int id) {
    var low = 0;
    var high = _ids.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final value = _ids[mid];
      if (value == id) return mid;
      if (value < id) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return -1;
  }

  /// Approximate heap cost in bytes.
  int get byteSize =>
      _ids.lengthInBytes + _lat.lengthInBytes + _lon.lengthInBytes;

  @override
  String toString() => 'NodeStore($length ids, $byteSize bytes)';
}
