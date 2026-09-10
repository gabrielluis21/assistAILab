/**
 * FIN-F02 organization civil-time primitives.
 *
 * Instants remain UTC.
 * Civil dates are derived using the persisted IANA timezone.
 */

export function normalizeIanaTimeZone(
  value: string
): string {
  const timeZone =
    value.trim();

  if (!timeZone) {
    throw new RangeError(
      'Organization timezone is required'
    );
  }

  try {
    new Intl.DateTimeFormat(
      'en-US',
      {
        timeZone,
      }
    ).format(
      new Date(0)
    );
  } catch {
    throw new RangeError(
      'Organization timezone must be a valid IANA timezone'
    );
  }

  return timeZone;
}

export function organizationLocalDateKey(
  instant: Date,
  organizationTimeZone: string
): string {
  if (
    Number.isNaN(
      instant.getTime()
    )
  ) {
    throw new RangeError(
      'Instant must be a valid Date'
    );
  }

  const timeZone =
    normalizeIanaTimeZone(
      organizationTimeZone
    );

  const parts =
    new Intl.DateTimeFormat(
      'en-CA',
      {
        timeZone,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
      }
    )
      .formatToParts(
        instant
      );

  const values =
    new Map(
      parts.map(
        (part) => [
          part.type,
          part.value,
        ]
      )
    );

  const year =
    values.get('year');
  const month =
    values.get('month');
  const day =
    values.get('day');

  if (
    !year ||
    !month ||
    !day
  ) {
    throw new RangeError(
      'Could not derive organization-local calendar date'
    );
  }

  return (
    year +
    '-' +
    month +
    '-' +
    day
  );
}

export function civilDateKeyToUtcDate(
  civilDateKey: string
): Date {
  const match =
    /^(\d{4})-(\d{2})-(\d{2})$/
      .exec(
        civilDateKey
      );

  if (!match) {
    throw new RangeError(
      'Civil date must use YYYY-MM-DD'
    );
  }

  const year =
    Number(match[1]);
  const month =
    Number(match[2]);
  const day =
    Number(match[3]);

  const result =
    new Date(
      Date.UTC(
        year,
        month - 1,
        day
      )
    );

  const roundTrip =
    result
      .toISOString()
      .slice(
        0,
        10
      );

  if (
    roundTrip !==
    civilDateKey
  ) {
    throw new RangeError(
      'Civil date is invalid'
    );
  }

  return result;
}

export function organizationLocalCivilDate(
  instant: Date,
  organizationTimeZone: string
): Date {
  return civilDateKeyToUtcDate(
    organizationLocalDateKey(
      instant,
      organizationTimeZone
    )
  );
}
