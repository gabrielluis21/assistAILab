import {
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import bcrypt from 'bcrypt';

const HISTORICAL_PASSWORD =
  'AssistAiLab-SEC-DEP-01-Legacy-Password!';

const HISTORICAL_BCRYPT5_HASH =
  '$2b$12$X6DcXemXVYnj3IZIzm6cleCYJKOpDcsuAmwRBy2FguJYz/V/2fGYm';

const SALT_ROUNDS =
  12;

describe(
  'SEC-DEP-01 bcrypt compatibility',
  {
    concurrency:
      false,
  },
  () => {
    test(
      'bcrypt 6 validates the approved historical bcrypt 5 hash',
      async () => {
        const historicalHash =
          HISTORICAL_BCRYPT5_HASH;

        const valid =
          await bcrypt.compare(
            HISTORICAL_PASSWORD,
            historicalHash
          );

        assert.equal(
          valid,
          true
        );

        assert.equal(
          historicalHash,
          HISTORICAL_BCRYPT5_HASH
        );
      }
    );

    test(
      'bcrypt 6 creates a fresh cost-12 hash and validates it',
      async () => {
        const freshHash =
          await bcrypt.hash(
            HISTORICAL_PASSWORD,
            SALT_ROUNDS
          );

        assert.match(
          freshHash,
          /^\$2[aby]\$12\$/
        );

        const valid =
          await bcrypt.compare(
            HISTORICAL_PASSWORD,
            freshHash
          );

        assert.equal(
          valid,
          true
        );

        assert.notEqual(
          freshHash,
          HISTORICAL_BCRYPT5_HASH
        );
      }
    );

    test(
      'bcrypt comparison rejects an incorrect password without changing the historical hash',
      async () => {
        const historicalHash =
          HISTORICAL_BCRYPT5_HASH;

        const valid =
          await bcrypt.compare(
            `${HISTORICAL_PASSWORD}-wrong`,
            historicalHash
          );

        assert.equal(
          valid,
          false
        );

        assert.equal(
          historicalHash,
          HISTORICAL_BCRYPT5_HASH
        );
      }
    );
  }
);
