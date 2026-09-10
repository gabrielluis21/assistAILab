import 'package:hive/hive.dart';

import '../../domain/entities/offline_authority_record.dart';
import '../../domain/repositories/offline_authority_store.dart';

final class HiveOfflineAuthorityStore implements OfflineAuthorityStore {
  static const String boxName = 'auth_offline_authority_v1';
  static const String recordKey = 'authority_record';

  @override
  Future<OfflineAuthorityRecord?> read() async {
    final value = (await Hive.openBox<dynamic>(boxName)).get(recordKey);
    if (value == null) return null;
    if (value is! Map) {
      throw const FormatException('Offline authority record is not a map.');
    }
    return OfflineAuthorityRecord.fromJson(value.cast<Object?, Object?>());
  }

  @override
  Future<void> write(OfflineAuthorityRecord record) async {
    await (await Hive.openBox<dynamic>(boxName)).put(
      recordKey,
      record.toJson(),
    );
  }

  @override
  Future<void> delete() async {
    await (await Hive.openBox<dynamic>(boxName)).delete(recordKey);
  }
}
