import assert from 'node:assert/strict';

/** Exact allowlist also catches future additions, not only today's denylist. */
export function assertCustomerOrderPrivacy(data: any) {
  assert.deepEqual(Object.keys(data).sort(), [
    'contractVersion', 'projectionRevision', 'id', 'friendlyId', 'equipmentId',
    'status', 'problemDescription', 'solution', 'createdAt', 'updatedAt',
    'diagnosis', 'totalAmountMinor', 'items',
  ].sort());
  assert.equal(data.contractVersion, 2);
  assert.match(data.projectionRevision, /^(0|[1-9][0-9]*)$/);
  assert.ok(Number.isSafeInteger(data.totalAmountMinor));
  let total = 0n;
  for (const line of data.items) {
    assert.deepEqual(Object.keys(line).sort(), ['description', 'quantity', 'unitPriceMinor', 'totalPriceMinor'].sort());
    assert.equal(typeof line.description, 'string');
    assert.ok(Number.isSafeInteger(line.quantity) && line.quantity > 0);
    assert.ok(Number.isSafeInteger(line.unitPriceMinor) && line.unitPriceMinor >= 0);
    assert.ok(Number.isSafeInteger(line.totalPriceMinor) && line.totalPriceMinor >= 0);
    assert.equal(BigInt(line.totalPriceMinor), BigInt(line.quantity) * BigInt(line.unitPriceMinor));
    total += BigInt(line.totalPriceMinor);
  }
  assert.equal(BigInt(data.totalAmountMinor), total);
}
