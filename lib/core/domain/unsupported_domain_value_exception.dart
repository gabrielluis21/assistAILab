final class UnsupportedDomainValueException implements Exception {
  const UnsupportedDomainValueException({
    required this.field,
    required this.receivedValue,
  });

  final String field;
  final Object? receivedValue;

  @override
  String toString() {
    final valueDescription = switch (receivedValue) {
      null => 'null',
      String value => '"$value"',
      Object value => '<${value.runtimeType}>',
    };
    return 'UnsupportedDomainValueException('
        'field: $field, receivedValue: $valueDescription)';
  }
}
