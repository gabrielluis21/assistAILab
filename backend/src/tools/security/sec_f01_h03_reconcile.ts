import {
  PrismaClient,
} from '@prisma/client';

import {
  applyH03Reconciliation,
  assertDisposableDatabase,
  evaluateH03Snapshot,
  readH03Snapshot,
} from '../../core/idempotency/sec_f01_h03_reconciliation.js';

async function main(): Promise<void> {
  const command = process.argv[2];

  if (
    command !== 'check' &&
    command !== 'apply'
  ) {
    console.error(
      'Usage: npx tsx src/tools/security/sec_f01_h03_reconcile.ts <check|apply>'
    );
    process.exitCode = 64;
    return;
  }

  const prisma = new PrismaClient();

  try {
    await assertDisposableDatabase(prisma);

    if (command === 'check') {
      const snapshot =
        await readH03Snapshot(prisma);

      const evaluation =
        evaluateH03Snapshot(snapshot);

      console.log(
        JSON.stringify(
          {
            command: 'check',
            state: evaluation.state,
            reasons: evaluation.reasons,
            migrationCounts: {
              old: snapshot.oldRows.length,
              new: snapshot.newRows.length,
              cleanup:
                snapshot.cleanupRows.length,
              h02: snapshot.h02Rows.length,
            },
            localMigrationChecksum:
              snapshot.localMigrationChecksum,
          },
          null,
          2
        )
      );

      if (
        evaluation.state === 'BLOCKED'
      ) {
        process.exitCode = 2;
      }

      return;
    }

    const result =
      await applyH03Reconciliation(
        prisma
      );

    console.log(
      JSON.stringify(
        {
          command: 'apply',
          result,
        },
        null,
        2
      )
    );
  } catch (error) {
    console.error(
      error instanceof Error
        ? error.message
        : String(error)
    );

    process.exitCode = 1;
  } finally {
    await prisma.$disconnect();
  }
}

void main();
