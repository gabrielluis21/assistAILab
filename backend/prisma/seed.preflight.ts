/** The manual legacy dataset is not the FE-02B integration-test fixture. */
export async function assertManualSeedTarget(
    environment: { NODE_ENV?: string; DATABASE_URL?: string },
    hasSyncBarrier: () => Promise<boolean>,
): Promise<void> {
    const database = environment.DATABASE_URL
        ? decodeURIComponent(new URL(environment.DATABASE_URL).pathname).replace(/^\//, '')
        : '';
    if (environment.NODE_ENV === 'test' || database === 'assistailab_fe02b_test') {
        throw new Error('MANUAL_SEED_TEST_DATABASE_BLOCKED: the test suite creates its own fixtures; do not seed the FE-02B gate database.');
    }
    if (await hasSyncBarrier()) {
        throw new Error('MANUAL_SEED_SYNC_ACTIVE: this legacy seed writes directly to Prisma and cannot run after FE-02B Sync initialization. Use a separate offline demo database.');
    }
}
