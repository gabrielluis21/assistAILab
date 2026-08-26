import crypto from 'node:crypto';

export class UnsupportedCanonicalValueError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'UnsupportedCanonicalValueError';
  }
}

export type CanonicalJsonValue =
  | null
  | string
  | boolean
  | number
  | CanonicalJsonValue[]
  | { [key: string]: CanonicalJsonValue };

function isPlainJsonObject(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== 'object') {
    return false;
  }

  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

export function canonicalize(value: unknown): CanonicalJsonValue {
  if (value === null) {
    return null;
  }

  if (typeof value === 'string' || typeof value === 'boolean') {
    return value;
  }

  if (typeof value === 'number') {
    if (!Number.isFinite(value)) {
      throw new UnsupportedCanonicalValueError(
        'Canonical JSON accepts only finite numbers'
      );
    }

    return Object.is(value, -0) ? 0 : value;
  }

  if (Array.isArray(value)) {
    return value.map((item) => canonicalize(item));
  }

  if (isPlainJsonObject(value)) {
    const result: Record<string, CanonicalJsonValue> = {};

    for (const key of Object.keys(value).sort()) {
      const child = value[key];

      if (child === undefined) {
        throw new UnsupportedCanonicalValueError(
          `Undefined is not allowed in canonical JSON at key "${key}"`
        );
      }

      result[key] = canonicalize(child);
    }

    return result;
  }

  const typeName =
    value === undefined
      ? 'undefined'
      : typeof value === 'bigint'
        ? 'bigint'
        : typeof value === 'function'
          ? 'function'
          : typeof value === 'symbol'
            ? 'symbol'
            : value instanceof Date
              ? 'Date'
              : value instanceof Map
                ? 'Map'
                : value instanceof Set
                  ? 'Set'
                  : value instanceof RegExp
                    ? 'RegExp'
                    : value?.constructor?.name ?? typeof value;

  throw new UnsupportedCanonicalValueError(
    `Unsupported canonical JSON value: ${typeName}`
  );
}

export function canonicalJsonStringify(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}

export function computeCanonicalHash(value: unknown): string {
  return crypto
    .createHash('sha256')
    .update(canonicalJsonStringify(value), 'utf8')
    .digest('hex');
}
