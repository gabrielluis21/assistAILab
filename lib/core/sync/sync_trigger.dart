/// Triggers that can request a synchronization cycle.
enum SyncTrigger {
  authenticated,
  localMutation,
  periodic,
  connectivityRestored,
  appResumed,
  manual,
  scheduledConsolidation,
}
