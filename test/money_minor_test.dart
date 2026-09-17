import 'package:assistailab/core/money/legacy_money_major_adapter.dart';
import 'package:assistailab/core/money/money_minor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MoneyMinor authority', () {
    test('integer and JSON roundtrip are exact', () {
      final value = MoneyMinor.fromJson(12345);
      expect(value.minorUnits, 12345);
      expect(value.toJson(), 12345);
      expect(MoneyMinor.fromJson(value.toJson()), value);
    });

    test('rejects non-integer authoritative JSON', () {
      for (final value in <Object?>[123.0, '123', null, true]) {
        expect(() => MoneyMinor.fromJson(value), throwsFormatException);
      }
    });

    test('equality, comparison and exact arithmetic', () {
      final cent = MoneyMinor(1);
      expect(cent, MoneyMinor(1));
      expect(cent < MoneyMinor(2), isTrue);
      expect(MoneyMinor(10).add(MoneyMinor(5)), MoneyMinor(15));
      expect(MoneyMinor(10).subtract(MoneyMinor(5)), MoneyMinor(5));
      expect(
        MoneyMinor.serviceOrder(1999).multiplyByQuantity(
          3,
          maximum: MoneyMinor.serviceOrderMaximum,
        ),
        MoneyMinor.serviceOrder(5997),
      );
    });

    test('range and arithmetic overflow fail closed', () {
      expect(() => MoneyMinor(-1), throwsRangeError);
      expect(
        () => MoneyMinor(MoneyMinor.generalMaximum + 1),
        throwsRangeError,
      );
      expect(
        () => MoneyMinor(MoneyMinor.generalMaximum).add(MoneyMinor(1)),
        throwsRangeError,
      );
      expect(() => MoneyMinor(1).subtract(MoneyMinor(2)), throwsRangeError);
      expect(
        () => MoneyMinor.serviceOrder(5000000000).multiplyByQuantity(
          2,
          maximum: MoneyMinor.serviceOrderMaximum,
        ),
        throwsRangeError,
      );
    });

    test('repeated cents and aggregates have no drift', () {
      final values = List.generate(10000, (_) => MoneyMinor(1));
      expect(MoneyMinor.sum(values), MoneyMinor(10000));
      expect(
        MoneyMinor.sum(
          [MoneyMinor.serviceOrder(1), MoneyMinor.serviceOrder(2)],
          maximum: MoneyMinor.serviceOrderMaximum,
        ),
        MoneyMinor.serviceOrder(3),
      );
    });
  });

  group('human money input', () {
    test('parses supported decimal text directly to minor units', () {
      expect(parseMoneyInput('123'), MoneyMinor(12300));
      expect(parseMoneyInput('123,45'), MoneyMinor(12345));
      expect(parseMoneyInput('0,01'), MoneyMinor(1));
      expect(parseMoneyInput('123.45'), MoneyMinor(12345));
    });

    test('rejects malformed, excess precision and ambiguous separators', () {
      for (final value in ['', 'abc', '1,234', '1.2.3', '1,2.3', '1.000,00']) {
        expect(() => parseMoneyInput(value), throwsA(anything));
      }
    });

    test('enforces sign, zero and overflow policies', () {
      expect(() => parseMoneyInput('-1'), throwsFormatException);
      expect(() => parseMoneyInput('+1'), throwsFormatException);
      expect(parseMoneyInput('0'), MoneyMinor.zero);
      expect(() => parseMoneyInput('0', allowZero: false), throwsRangeError);
      expect(
        () => parseMoneyInput('1000000000000'),
        throwsRangeError,
      );
    });
  });

  test('legacy SQLite adapter validates rather than rounds', () {
    expect(legacySqliteMajorToMinor(123), MoneyMinor(12300));
    expect(legacySqliteMajorToMinor(123.45), MoneyMinor(12345));
    expect(
      () => legacySqliteMajorToMinor(0.1 + 0.2),
      throwsFormatException,
    );
    expect(() => legacySqliteMajorToMinor(1.001), throwsFormatException);
    expect(() => legacySqliteMajorToMinor('1.00'), throwsFormatException);
  });

  test('formats Brazilian currency directly from minor units', () {
    expect(formatMoneyMinor(MoneyMinor(1)), r'R$ 0,01');
    expect(formatMoneyMinor(MoneyMinor(123456)), r'R$ 1.234,56');
    expect(
      formatMoneyMinor(MoneyMinor(12345), includeSymbol: false),
      '123,45',
    );
    expect(formatMoneyMinorForInput(MoneyMinor(123456)), '1234,56');
    expect(parseMoneyInput(formatMoneyMinorForInput(MoneyMinor(123456))),
        MoneyMinor(123456));
  });
}
