import 'credential_epoch.dart';

abstract interface class CredentialEpochStore {
  Future<CredentialEpoch?> read();

  Future<void> write(CredentialEpoch epoch);
}
