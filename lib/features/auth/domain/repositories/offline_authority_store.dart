import '../entities/offline_authority_record.dart';

abstract interface class OfflineAuthorityStore {
  Future<OfflineAuthorityRecord?> readByCredentialId(String credentialId);

  Future<void> write(OfflineAuthorityRecord record);

  Future<void> deleteByCredentialId(String credentialId);
}
