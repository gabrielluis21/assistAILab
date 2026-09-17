import 'package:flutter/foundation.dart';

/// Exact, immutable monetary value represented exclusively in minor units.
///
/// JSON authority is intentionally strict: only an integer is accepted. Text
/// entered by a person belongs to [parseMoneyInput], not to this boundary.
@immutable
final class MoneyMinor implements Comparable<MoneyMinor> {
  static const int serviceOrderMaximum = 9999999999;
  static const int generalMaximum = 99999999999999;

  final int minorUnits;

  const MoneyMinor._(this.minorUnits);

  static const zero = MoneyMinor._(0);

  factory MoneyMinor(int minorUnits, {int maximum = generalMaximum}) {
    _validate(minorUnits, maximum);
    return MoneyMinor._(minorUnits);
  }

  factory MoneyMinor.serviceOrder(int minorUnits) =>
      MoneyMinor(minorUnits, maximum: serviceOrderMaximum);

  factory MoneyMinor.fromJson(Object? value, {int maximum = generalMaximum}) {
    if (value is! int) {
      throw const FormatException(
          'Authoritative money must be a JSON integer.');
    }
    return MoneyMinor(value, maximum: maximum);
  }

  factory MoneyMinor.serviceOrderFromJson(Object? value) =>
      MoneyMinor.fromJson(value, maximum: serviceOrderMaximum);

  static void _validate(int value, int maximum) {
    if (maximum < 0 || maximum > generalMaximum) {
      throw RangeError.range(maximum, 0, generalMaximum, 'maximum');
    }
    if (value < 0 || value > maximum) {
      throw RangeError.range(value, 0, maximum, 'minorUnits');
    }
  }

  int toJson() => minorUnits;

  MoneyMinor add(MoneyMinor other, {int maximum = generalMaximum}) {
    final result = BigInt.from(minorUnits) + BigInt.from(other.minorUnits);
    return _fromCheckedBigInt(result, maximum: maximum);
  }

  MoneyMinor subtract(MoneyMinor other, {int maximum = generalMaximum}) {
    final result = BigInt.from(minorUnits) - BigInt.from(other.minorUnits);
    return _fromCheckedBigInt(result, maximum: maximum);
  }

  MoneyMinor multiplyByQuantity(
    int quantity, {
    int maximum = generalMaximum,
  }) {
    if (quantity < 0 || quantity > 2147483647) {
      throw RangeError.range(quantity, 0, 2147483647, 'quantity');
    }
    return _fromCheckedBigInt(
      BigInt.from(minorUnits) * BigInt.from(quantity),
      maximum: maximum,
    );
  }

  static MoneyMinor sum(
    Iterable<MoneyMinor> values, {
    int maximum = generalMaximum,
  }) {
    var total = BigInt.zero;
    for (final value in values) {
      total += BigInt.from(value.minorUnits);
    }
    return _fromCheckedBigInt(total, maximum: maximum);
  }

  static MoneyMinor _fromCheckedBigInt(
    BigInt value, {
    required int maximum,
  }) {
    if (value < BigInt.zero || value > BigInt.from(maximum)) {
      throw RangeError('Money result is outside the authoritative range.');
    }
    return MoneyMinor(value.toInt(), maximum: maximum);
  }

  @override
  int compareTo(MoneyMinor other) => minorUnits.compareTo(other.minorUnits);

  bool operator <(MoneyMinor other) => compareTo(other) < 0;
  bool operator <=(MoneyMinor other) => compareTo(other) <= 0;
  bool operator >(MoneyMinor other) => compareTo(other) > 0;
  bool operator >=(MoneyMinor other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MoneyMinor && minorUnits == other.minorUnits;

  @override
  int get hashCode => minorUnits.hashCode;

  @override
  String toString() => 'MoneyMinor($minorUnits)';
}

/// Parses human-entered decimal text without ever using floating point.
MoneyMinor parseMoneyInput(
  String input, {
  bool allowZero = true,
  int maximum = MoneyMinor.generalMaximum,
}) {
  final text = input.trim();
  if (text.isEmpty || text.length > 32) {
    throw const FormatException('Invalid monetary input.');
  }
  final match =
      RegExp(r'^(0|[1-9][0-9]*)(?:([,.])([0-9]{1,2}))?$').firstMatch(text);
  if (match == null) {
    throw const FormatException('Use at most two decimal places.');
  }
  final whole = BigInt.parse(match.group(1)!);
  final fraction = (match.group(3) ?? '').padRight(2, '0');
  final value = whole * BigInt.from(100) +
      (fraction.isEmpty ? BigInt.zero : BigInt.parse(fraction));
  if ((!allowZero && value == BigInt.zero) || value > BigInt.from(maximum)) {
    throw RangeError('Monetary input is outside the accepted range.');
  }
  return MoneyMinor(value.toInt(), maximum: maximum);
}

/// Formats directly from integer minor units using Brazilian separators.
String formatMoneyMinor(MoneyMinor value, {bool includeSymbol = true}) {
  final whole = value.minorUnits ~/ 100;
  final cents = (value.minorUnits % 100).toString().padLeft(2, '0');
  final digits = whole.toString();
  final grouped = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) grouped.write('.');
    grouped.write(digits[index]);
  }
  final formatted = '${grouped.toString()},$cents';
  return includeSymbol ? 'R\$ $formatted' : formatted;
}

/// Produces an ungrouped decimal value that can be fed back to
/// [parseMoneyInput] without introducing an ambiguous separator.
String formatMoneyMinorForInput(MoneyMinor value) {
  final whole = value.minorUnits ~/ 100;
  final cents = (value.minorUnits % 100).toString().padLeft(2, '0');
  return '$whole,$cents';
}
