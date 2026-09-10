import '../entities/offline_authority_record.dart';

abstract interface class OfflineAuthorityStore {
  Future<OfflineAuthorityRecord?> read();

  Future<void> write(OfflineAuthorityRecord record);

  Future<void> delete();
}
