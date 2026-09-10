import test from 'node:test';
import assert from 'node:assert/strict';

import {
  civilDateKeyToUtcDate,
  normalizeIanaTimeZone,
  organizationLocalCivilDate,
  organizationLocalDateKey,
} from './organization_time.js';

test(
  'FIN-F02 accepts valid IANA organization timezone',
  () => {
    assert.equal(
      normalizeIanaTimeZone(
        'America/Sao_Paulo'
      ),
      'America/Sao_Paulo'
    );
  }
);

test(
  'FIN-F02 rejects invalid organization timezone',
  () => {
    assert.throws(
      () =>
        normalizeIanaTimeZone(
          'Not/A_Real_Zone'
        ),
      RangeError
    );
  }
);

test(
  'FIN-F02 derives civil date using organization timezone, not host timezone',
  () => {
    const instant =
      new Date(
        '2026-09-01T01:30:00.000Z'
      );

    assert.equal(
      organizationLocalDateKey(
        instant,
        'America/Sao_Paulo'
      ),
      '2026-08-31'
    );

    assert.equal(
      organizationLocalDateKey(
        instant,
        'UTC'
      ),
      '2026-09-01'
    );
  }
);

test(
  'FIN-F02 civil DATE representation round-trips without timezone drift',
  () => {
    assert.equal(
      civilDateKeyToUtcDate(
        '2026-09-09'
      )
        .toISOString(),
      '2026-09-09T00:00:00.000Z'
    );

    assert.equal(
      organizationLocalCivilDate(
        new Date(
          '2026-09-01T01:30:00.000Z'
        ),
        'America/Sao_Paulo'
      )
        .toISOString(),
      '2026-08-31T00:00:00.000Z'
    );
  }
);

test(
  'FIN-F02 rejects impossible civil calendar dates',
  () => {
    assert.throws(
      () =>
        civilDateKeyToUtcDate(
          '2026-02-30'
        ),
      RangeError
    );
  }
);
