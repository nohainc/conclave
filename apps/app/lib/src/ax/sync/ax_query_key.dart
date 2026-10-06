/// Structural identity: resource IDs cannot collide with separators in keys.
class AxQueryKey {
  AxQueryKey(Iterable<String> parts) : parts = List.unmodifiable(parts) {
    if (this.parts.isEmpty || this.parts.any((part) => part.isEmpty)) {
      throw ArgumentError('Query keys require nonempty parts');
    }
  }

  final List<String> parts;

  bool startsWith(AxQueryKey prefix) =>
      parts.length >= prefix.parts.length &&
      Iterable.generate(prefix.parts.length).every(
        (index) => parts[index] == prefix.parts[index],
      );

  @override
  bool operator ==(Object other) =>
      other is AxQueryKey &&
      parts.length == other.parts.length &&
      startsWith(other);

  @override
  int get hashCode => Object.hashAll(parts);

  @override
  String toString() => parts.map(Uri.encodeComponent).join(':');
}
