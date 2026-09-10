import {
  after,
  before,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import {
  randomUUID,
} from 'node:crypto';

import bcrypt from 'bcrypt';

import type {
  FastifyInstance,
} from 'fastify';

import {
  CustomerOrganizationStatus,
  EquipmentOwnerType,
  OperationType,
  Prisma,
  QuoteChangeType,
  ReceivableLifecycleStatus,
  Role,
  ServiceOrderStatus,
  UserStatus,
} from '@prisma/client';

import {
  buildApp,
} from '../../app.js';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  computeCanonicalHash,
} from '../../core/idempotency/canonical_json.js';

const runId =
  randomUUID();

const organizationId =
  randomUUID();

const adminId =
  randomUUID();

const customerId =
  randomUUID();

const password =
  'FIN-F02-R02@Test-2026';

const adminEmail =
  `fin-f02-r02-${runId}@assistailab.test`;

const v2RestOrderId =
  randomUUID();

const v2SyncOrderId =
  randomUUID();

const legacyRestOrderId =
  randomUUID();

const legacySyncOrderId =
  randomUUID();

const orderIds = [
  v2RestOrderId,
  v2SyncOrderId,
  legacyRestOrderId,
  legacySyncOrderId,
];

const equipmentIds =
  orderIds.map(
    () => randomUUID()
  );

let app:
  FastifyInstance;

let token:
  string;

let oldJwtSecret:
  string | undefined;

async function createReadyV2FinanceOrder(
  serviceOrderId:
    string,
  equipmentId:
    string,
  label:
    string
) {
  await prisma.equipment.create({
    data: {
      id:
        equipmentId,

      customerId,

      ownerType:
        EquipmentOwnerType.CUSTOMER,

      type:
        'NOTEBOOK',

      brand:
        'FIN-F02-R02',

      model:
        label,
    },
  });

  const order =
    await prisma.serviceOrder.create({
      data: {
        id:
          serviceOrderId,

        organizationId,

        customerId,

        equipmentId,

        status:
          ServiceOrderStatus.PRONTO,

        financeCoreVersion:
          2,

        problemDescription:
          `R02 ${label}`,

        diagnosis:
          'Approved R02 scope',

        totalAmount:
          new Prisma.Decimal(
            '500.00'
          ),
      },
    });

  const quoteSnapshot = {
    snapshotVersion:
      1,

    serviceOrderId,

    organizationId,

    customerId,

    diagnosis:
      order.diagnosis,

    totalAmount:
      '500.00',

    serviceItems: [],
    parts: [],
  };

  const revision =
    await prisma.serviceOrderQuoteRevision.create({
      data: {
        serviceOrderId,

        organizationId,

        customerId,

        revisionNumber:
          1,

        diagnosisSnapshot:
          order.diagnosis,

        serviceItemsSnapshot:
          [],

        partsSnapshot:
          [],

        totalAmount:
          new Prisma.Decimal(
            '500.00'
          ),

        changeType:
          QuoteChangeType.INITIAL,

        changeReason:
          'FIN-F02-R02 fixture',

        quoteSnapshot:
          quoteSnapshot as
            Prisma.InputJsonValue,

        quoteHash:
          computeCanonicalHash(
            quoteSnapshot
          ),

        createdByUserId:
          adminId,
      },
    });

  await prisma.serviceOrder.update({
    where: {
      id:
        serviceOrderId,
    },

    data: {
      currentQuoteRevisionId:
        revision.id,

      lastApprovedQuoteRevisionId:
        revision.id,
    },
  });

  const receivable =
    await prisma.receivable.create({
      data: {
        organizationId,

        customerId,

        serviceOrderId,

        sourceQuoteRevisionId:
          revision.id,

        totalAmount:
          new Prisma.Decimal(
            '500.00'
          ),

        lifecycleStatus:
          ReceivableLifecycleStatus.ACTIVE,

        currentScheduleVersion:
          1,

        version:
          1,

        issuedAt:
          new Date(),

        createdByUserId:
          adminId,
      },
    });

  const schedule =
    await prisma.receivableSchedule.create({
      data: {
        organizationId,

        receivableId:
          receivable.id,

        version:
          1,

        createdByUserId:
          adminId,
      },
    });

  await prisma.receivableInstallment.create({
    data: {
      organizationId,

      receivableId:
        receivable.id,

      scheduleId:
        schedule.id,

      scheduleVersion:
        1,

      sequence:
        1,

      amount:
        new Prisma.Decimal(
          '500.00'
        ),

      dueDate:
        new Date(
          '2026-09-02T00:00:00.000Z'
        ),
    },
  });

  return receivable;
}

async function createLegacyReadyOrder(
  serviceOrderId:
    string,
  equipmentId:
    string,
  label:
    string
) {
  await prisma.equipment.create({
    data: {
      id:
        equipmentId,

      customerId,

      ownerType:
        EquipmentOwnerType.CUSTOMER,

      type:
        'NOTEBOOK',

      brand:
        'FIN-F01-LEGACY',

      model:
        label,
    },
  });

  await prisma.serviceOrder.create({
    data: {
      id:
        serviceOrderId,

      organizationId,

      customerId,

      equipmentId,

      status:
        ServiceOrderStatus.PRONTO,

      financeCoreVersion:
        null,

      problemDescription:
        `Legacy ${label}`,

      totalAmount:
        new Prisma.Decimal(
          '0.00'
        ),
    },
  });
}

before(
  async () => {
    oldJwtSecret =
      process.env.JWT_SECRET;

    process.env.JWT_SECRET =
      'fin-f02-r02-integration-secret-2026';

    const passwordHash =
      await bcrypt.hash(
        password,
        12
      );

    await prisma.organization.create({
      data: {
        id:
          organizationId,

        name:
          `FIN-F02-R02 Org ${runId}`,
      },
    });

    await prisma.user.create({
      data: {
        id:
          adminId,

        name:
          'FIN-F02-R02 Admin',

        email:
          adminEmail,

        passwordHash,

        role:
          Role.ADMIN,

        status:
          UserStatus.ACTIVE,
      },
    });

    await prisma.membership.create({
      data: {
        userId:
          adminId,

        organizationId,

        role:
          Role.ADMIN,
      },
    });

    await prisma.customer.create({
      data: {
        id:
          customerId,

        name:
          'FIN-F02-R02 Customer',
      },
    });

    await prisma.customerOrganization.create({
      data: {
        customerId,

        organizationId,

        status:
          CustomerOrganizationStatus.ACTIVE,
      },
    });

    await createReadyV2FinanceOrder(
      v2RestOrderId,
      equipmentIds[0],
      'REST'
    );

    await createReadyV2FinanceOrder(
      v2SyncOrderId,
      equipmentIds[1],
      'SYNC'
    );

    await createLegacyReadyOrder(
      legacyRestOrderId,
      equipmentIds[2],
      'REST'
    );

    await createLegacyReadyOrder(
      legacySyncOrderId,
      equipmentIds[3],
      'SYNC'
    );

    app =
      buildApp();

    await app.ready();

    const login =
      await app.inject({
        method:
          'POST',

        url:
          '/api/v1/auth/login',

        payload: {
          email:
            adminEmail,

          password,
        },
      });

    assert.equal(
      login.statusCode,
      200
    );

    token =
      login.json().token;
  }
);

after(
  async () => {
    /**
     * This integration suite is intentionally executed by the FIN-F02
     * gates on a disposable database. V2 fixtures contain immutable /
     * append-only financial history, so destructive row cleanup here
     * would contradict the production integrity model.
     */
    await app.close();

    if (oldJwtSecret) {
      process.env.JWT_SECRET =
        oldJwtSecret;
    } else {
      delete process.env.JWT_SECRET;
    }
  }
);

test(
  'FIN-F02-R02 REST denies generic PRONTO -> CANCELADO without financial or sync side effects',
  async () => {
    const beforeReceivable =
      await prisma.receivable.findFirstOrThrow({
        where: {
          serviceOrderId:
            v2RestOrderId,
        },
      });

    const beforeHistory =
      await prisma.serviceOrderStatusHistory.count({
        where: {
          serviceOrderId:
            v2RestOrderId,
        },
      });

    const beforeSync =
      await prisma.syncChangeLog.count({
        where: {
          entityType:
            'SERVICE_ORDER',

          entityId:
            v2RestOrderId,
        },
      });

    const response =
      await app.inject({
        method:
          'PATCH',

        url:
          `/api/v1/service-orders/${v2RestOrderId}/status`,

        headers: {
          authorization:
            `Bearer ${token}`,
        },

        payload: {
          newStatus:
            ServiceOrderStatus.CANCELADO,
        },
      });

    assert.equal(
      response.statusCode,
      409
    );

    assert.equal(
      response.json().error,
      'FINANCE_COMMAND_REQUIRED'
    );

    const order =
      await prisma.serviceOrder.findUniqueOrThrow({
        where: {
          id:
            v2RestOrderId,
        },
      });

    assert.equal(
      order.status,
      ServiceOrderStatus.PRONTO
    );

    const afterReceivable =
      await prisma.receivable.findUniqueOrThrow({
        where: {
          id:
            beforeReceivable.id,
        },
      });

    assert.equal(
      afterReceivable.lifecycleStatus,
      beforeReceivable.lifecycleStatus
    );

    assert.equal(
      afterReceivable.version,
      beforeReceivable.version
    );

    assert.equal(
      afterReceivable.currentScheduleVersion,
      beforeReceivable.currentScheduleVersion
    );

    assert.equal(
      await prisma.serviceOrderStatusHistory.count({
        where: {
          serviceOrderId:
            v2RestOrderId,
        },
      }),
      beforeHistory
    );

    assert.equal(
      await prisma.syncChangeLog.count({
        where: {
          entityType:
            'SERVICE_ORDER',

          entityId:
            v2RestOrderId,
        },
      }),
      beforeSync
    );
  }
);

test(
  'FIN-F02-R02 Sync denies generic PRONTO -> CANCELADO without false history or ChangeLog',
  async () => {
    const operationId =
      randomUUID();

    const beforeReceivable =
      await prisma.receivable.findFirstOrThrow({
        where: {
          serviceOrderId:
            v2SyncOrderId,
        },
      });

    const beforeHistory =
      await prisma.serviceOrderStatusHistory.count({
        where: {
          serviceOrderId:
            v2SyncOrderId,
        },
      });

    const beforeSync =
      await prisma.syncChangeLog.count({
        where: {
          entityType:
            'SERVICE_ORDER',

          entityId:
            v2SyncOrderId,
        },
      });

    const response =
      await app.inject({
        method:
          'POST',

        url:
          '/api/v1/sync/push',

        headers: {
          authorization:
            `Bearer ${token}`,
        },

        payload: {
          entries: [
            {
              operationId,

              entityType:
                'SERVICE_ORDER',

              entityId:
                v2SyncOrderId,

              operationType:
                'UPDATE',

              payload: {
                customerId,

                equipmentId:
                  equipmentIds[1],

                status:
                  ServiceOrderStatus.CANCELADO,

                problemDescription:
                  'R02 SYNC',
              },

              createdAt:
                new Date()
                  .toISOString(),
            },
          ],
        },
      });

    assert.equal(
      response.statusCode,
      200
    );

    assert.equal(
      response.json().results[0].status,
      'FAILED'
    );

    assert.equal(
      response.json().results[0].error,
      'CONFLICT: FINANCE_COMMAND_REQUIRED'
    );

    const order =
      await prisma.serviceOrder.findUniqueOrThrow({
        where: {
          id:
            v2SyncOrderId,
        },
      });

    assert.equal(
      order.status,
      ServiceOrderStatus.PRONTO
    );

    const afterReceivable =
      await prisma.receivable.findUniqueOrThrow({
        where: {
          id:
            beforeReceivable.id,
        },
      });

    assert.equal(
      afterReceivable.lifecycleStatus,
      beforeReceivable.lifecycleStatus
    );

    assert.equal(
      afterReceivable.version,
      beforeReceivable.version
    );

    assert.equal(
      await prisma.serviceOrderStatusHistory.count({
        where: {
          serviceOrderId:
            v2SyncOrderId,
        },
      }),
      beforeHistory
    );

    assert.equal(
      await prisma.syncChangeLog.count({
        where: {
          entityType:
            'SERVICE_ORDER',

          entityId:
            v2SyncOrderId,
        },
      }),
      beforeSync
    );

    assert.equal(
      await prisma.operationIdempotency.count({
        where: {
          operationId,
        },
      }),
      0
    );
  }
);

test(
  'FIN-F02-R02 preserves legacy PRONTO -> CANCELADO through REST',
  async () => {
    const response =
      await app.inject({
        method:
          'PATCH',

        url:
          `/api/v1/service-orders/${legacyRestOrderId}/status`,

        headers: {
          authorization:
            `Bearer ${token}`,
        },

        payload: {
          newStatus:
            ServiceOrderStatus.CANCELADO,
        },
      });

    assert.equal(
      response.statusCode,
      200
    );

    assert.equal(
      response.json().order.status,
      ServiceOrderStatus.CANCELADO
    );

    assert.equal(
      await prisma.serviceOrderStatusHistory.count({
        where: {
          serviceOrderId:
            legacyRestOrderId,

          newStatus:
            ServiceOrderStatus.CANCELADO,
        },
      }),
      1
    );

    assert.equal(
      await prisma.syncChangeLog.count({
        where: {
          entityType:
            'SERVICE_ORDER',

          entityId:
            legacyRestOrderId,

          operationType:
            OperationType.UPDATE,
        },
      }),
      1
    );
  }
);

test(
  'FIN-F02-R02 preserves legacy PRONTO -> CANCELADO through Sync',
  async () => {
    const operationId =
      randomUUID();

    const response =
      await app.inject({
        method:
          'POST',

        url:
          '/api/v1/sync/push',

        headers: {
          authorization:
            `Bearer ${token}`,
        },

        payload: {
          entries: [
            {
              operationId,

              entityType:
                'SERVICE_ORDER',

              entityId:
                legacySyncOrderId,

              operationType:
                'UPDATE',

              payload: {
                customerId,

                equipmentId:
                  equipmentIds[3],

                status:
                  ServiceOrderStatus.CANCELADO,

                problemDescription:
                  'Legacy SYNC',
              },

              createdAt:
                new Date()
                  .toISOString(),
            },
          ],
        },
      });

    assert.equal(
      response.statusCode,
      200
    );

    assert.equal(
      response.json().results[0].status,
      'SYNCED'
    );

    const order =
      await prisma.serviceOrder.findUniqueOrThrow({
        where: {
          id:
            legacySyncOrderId,
        },
      });

    assert.equal(
      order.status,
      ServiceOrderStatus.CANCELADO
    );

    assert.equal(
      await prisma.serviceOrderStatusHistory.count({
        where: {
          serviceOrderId:
            legacySyncOrderId,

          newStatus:
            ServiceOrderStatus.CANCELADO,
        },
      }),
      1
    );

    assert.equal(
      await prisma.syncChangeLog.count({
        where: {
          entityType:
            'SERVICE_ORDER',

          entityId:
            legacySyncOrderId,

          operationType:
            OperationType.UPDATE,
        },
      }),
      1
    );
  }
);