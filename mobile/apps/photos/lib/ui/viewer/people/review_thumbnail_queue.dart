import "dart:async";

/// A bounded look-ahead window shared by face and body review. Slow candidates
/// stay pending while ready candidates can be presented in their original order.
class ReviewThumbnailQueue<K, V> {
  ReviewThumbnailQueue(
    this.load, {
    this.capacity = 2,
    this.maxWeight,
    int Function(K)? weight,
  }) : assert(capacity > 0),
       _weight = weight ?? ((_) => 1);

  final Future<V> Function(K) load;
  final int capacity;
  final int? maxWeight;
  final int Function(K) _weight;
  final Map<K, int> _weights = {};
  final Map<K, V> _ready = {};
  final Set<K> _pending = {};
  final Map<K, (Object, StackTrace)> _errors = {};
  Set<K> _wanted = {};
  Completer<void> _changed = Completer<void>();
  bool _disposed = false;

  void prefetch(Iterable<K> candidates) {
    if (_disposed) return;
    _wanted = candidates.toSet();
    _ready.removeWhere((key, _) => !_wanted.contains(key));
    _errors.removeWhere((key, _) => !_wanted.contains(key));
    _weights.removeWhere(
      (key, _) => !_ready.containsKey(key) && !_pending.contains(key),
    );
    for (final key in _wanted) {
      if (_ready.length + _pending.length >= capacity) break;
      if (_ready.containsKey(key) ||
          _pending.contains(key) ||
          _errors.containsKey(key)) {
        continue;
      }
      final weight = _weight(key);
      if (weight <= 0 || (maxWeight != null && weight > maxWeight!)) {
        _errors[key] = (
          StateError("Review candidate exceeds its image budget"),
          StackTrace.current,
        );
        continue;
      }
      final usedWeight = _weights.values.fold<int>(
        0,
        (sum, value) => sum + value,
      );
      if (maxWeight != null && usedWeight + weight > maxWeight!) continue;
      _weights[key] = weight;
      _pending.add(key);
      unawaited(_prepare(key));
    }
  }

  Future<void> _prepare(K key) async {
    try {
      final value = await load(key);
      if (!_disposed && _wanted.contains(key)) _ready[key] = value;
    } catch (error, stack) {
      if (!_disposed && _wanted.contains(key)) _errors[key] = (error, stack);
    } finally {
      _pending.remove(key);
      if (!_ready.containsKey(key)) _weights.remove(key);
      _notify();
    }
  }

  /// Returns null only when disposed or when there are no candidates. A failed
  /// load is never treated as a ready thumbnail; the caller can offer a retry.
  Future<({K key, V value})?> next(Iterable<K> candidates) async {
    final keys = candidates.toList(growable: false);
    if (keys.isEmpty) return null;
    prefetch(keys);
    while (!_disposed) {
      for (final key in keys) {
        if (_ready.containsKey(key)) {
          _weights.remove(key);
          return (key: key, value: _ready.remove(key) as V);
        }
      }
      if (!keys.any(_pending.contains)) {
        final failures = keys.where(_errors.containsKey).length;
        // Allow another whole group to fit after a weighted group fails, but
        // never walk the entire album when a complete window is offline.
        if (failures >= capacity || failures == keys.length) {
          final failure = keys.map((key) => _errors[key]).nonNulls.first;
          Error.throwWithStackTrace(failure.$1, failure.$2);
        }
        prefetch(keys);
      }
      await _changed.future;
    }
    return null;
  }

  void retryFailures() => _errors.clear();

  void _notify() {
    final previous = _changed;
    _changed = Completer<void>();
    if (!previous.isCompleted) previous.complete();
  }

  void dispose() {
    _disposed = true;
    _ready.clear();
    _weights.clear();
    _wanted.clear();
    _errors.clear();
    _notify();
  }
}
