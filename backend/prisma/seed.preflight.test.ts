import test from 'node:test';
import assert from 'node:assert/strict';
import { assertManualSeedTarget } from './seed.preflight.js';

test('manual seed refuses test environment before querying the database', async () => {
    await assert.rejects(assertManualSeedTarget({ NODE_ENV: 'test' }, async () => {
        assert.fail('test target must be rejected before database access');
    }), /MANUAL_SEED_TEST_DATABASE_BLOCKED/);
});

test('manual seed refuses the named FE-02B gate even outside NODE_ENV=test', async () => {
    await assert.rejects(assertManualSeedTarget({ DATABASE_URL: 'mysql://localhost/assistailab_fe02b_test' }, async () => {
        assert.fail('gate target must be rejected before database access');
    }), /MANUAL_SEED_TEST_DATABASE_BLOCKED/);
});

test('manual seed refuses an initialized Sync database', async () => {
    await assert.rejects(assertManualSeedTarget({ DATABASE_URL: 'mysql://localhost/manual_demo' }, async () => true), /MANUAL_SEED_SYNC_ACTIVE/);
});

test('manual seed allows a separate offline legacy demo before Sync initialization', async () => {
    await assertManualSeedTarget({ DATABASE_URL: 'mysql://localhost/manual_demo' }, async () => false);
});

test('manual seed fails closed when the Sync marker cannot be checked', async () => {
    await assert.rejects(assertManualSeedTarget({}, async () => { throw new Error('database unavailable'); }), /database unavailable/);
});
