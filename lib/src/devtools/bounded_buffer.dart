import 'dart:collection';

class BoundedBuffer<T> {
  BoundedBuffer(this.capacity) {
    if (capacity < 1) {
      throw RangeError.range(capacity, 1, null, 'capacity');
    }
  }

  final int capacity;
  final ListQueue<T> _items = ListQueue<T>();

  int _dropped = 0;

  int get length => _items.length;
  int get dropped => _dropped;
  bool get isEmpty => _items.isEmpty;
  T? get lastOrNull => _items.isEmpty ? null : _items.last;

  void add(T value) {
    if (_items.length == capacity) {
      _items.removeFirst();
      _dropped++;
    }
    _items.addLast(value);
  }

  List<T> tail([int? limit]) {
    if (limit != null && limit < 1) {
      throw RangeError.range(limit, 1, null, 'limit');
    }
    final skip = limit == null || limit >= _items.length
        ? 0
        : _items.length - limit;
    return List<T>.unmodifiable(_items.skip(skip));
  }

  void clear({bool resetDropped = true}) {
    _items.clear();
    if (resetDropped) _dropped = 0;
  }
}
