import 'money_minor.dart';

/// Explicit one-way adapter used only while migrating the legacy SQLite REAL
/// schema. It is validation, never a rounding policy.
MoneyMinor legacySqliteMajorToMinor(
  Object? value, {
  int maximum = MoneyMinor.generalMaximum,
}) {
  if (value is! int && value is! double) {
    throw const FormatException('Legacy SQLite money is not numeric.');
  }
  if (value is double &&
      (!value.isFinite || value.isNegative || value == double.infinity)) {
    throw const FormatException('Legacy SQLite money is invalid.');
  }
  final text = value.toString();
  final match =
      RegExp(r'^(0|[1-9][0-9]*)(?:\.([0-9]{1,2}))?$').firstMatch(text);
  if (match == null) {
    throw const FormatException(
      'Legacy SQLite money has ambiguous precision and cannot be migrated.',
    );
  }
  final whole = BigInt.parse(match.group(1)!);
  final fraction = (match.group(2) ?? '').padRight(2, '0');
  final minor = whole * BigInt.from(100) +
      (fraction.isEmpty ? BigInt.zero : BigInt.parse(fraction));
  if (minor > BigInt.from(maximum)) {
    throw RangeError('Legacy SQLite money exceeds the authoritative range.');
  }
  return MoneyMinor(minor.toInt(), maximum: maximum);
}
