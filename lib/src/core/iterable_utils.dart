/// Utility helpers for iterable lookups and list comparison.
extension IterableNullableLookup<E> on Iterable<E> {
  /// Returns the first element matching [test], or `null` if none match.
  E? firstWhereOrNull(bool Function(E element) test) {
    for (final element in this) {
      if (test(element)) {
        return element;
      }
    }
    return null;
  }
}

/// Returns `true` when [left] and [right] contain the same values in order.
bool listEquals<T>(List<T>? left, List<T>? right) {
  if (identical(left, right)) {
    return true;
  }
  if (left == null || right == null || left.length != right.length) {
    return false;
  }

  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
