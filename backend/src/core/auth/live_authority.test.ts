import {
  after,
  before,
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import {
  randomUUID,
} from 'node:crypto';

import type {
  FastifyInstance,
} from 'fastify';

import {
  CustomerOrganizationStatus,
  EquipmentOwnerType,
  OperationType,
  Role,
  UserStatus,
} from '@prisma/client';

import {
  buildApp,
} from '../../app.js';

import {
  prisma,
} from '../database/prisma.js';

describe(
  'AUTH-BE-01 live authority consistency',
  {
    concurrency:
      false,
  },
  () => {
    const runId =
      randomUUID();

    const organizationAId =
      randomUUID();

    const organizationBId =
      randomUUID();

    const professionalUserId =
      randomUUID();

    const customerAId =
      randomUUID();

    const customerBId =
      randomUUID();

    const customerUserId =
      randomUUID();

    const syncCustomerId =
      randomUUID();

    const syncEquipmentAId =
      randomUUID();

    const syncEquipmentBId =
      randomUUID();

    const syncOrderAId =
      randomUUID();

    const syncOrderBId =
      randomUUID();

    let baselineCursor =
      '0';

    let app:
      FastifyInstance;

    let previousJwtSecret:
      string | undefined;

    function professionalToken(
      role:
        'ADMIN' |
        'TECHNICIAN',
      organizationId:
        string
    ) {
      return app.jwt.sign({
        sub:
          professionalUserId,

        role,

        name:
          'AUTH-BE-01 Professional',

        customerId:
          null,

        organizationId,
      });
    }

    function customerToken() {
      return app.jwt.sign({
        sub:
          customerUserId,

        role:
          'CUSTOMER',

        name:
          'AUTH-BE-01 Customer',

        customerId:
          customerAId,

        organizationId:
          null,
      });
    }

    async function getMe(
      token:
        string
    ) {
      return app.inject({
        method:
          'GET',

        url:
          '/api/v1/auth/me',

        headers: {
          authorization:
            `Bearer ${token}`,
        },
      });
    }

    before(
      async () => {
        previousJwtSecret =
          process.env.JWT_SECRET;

        process.env.JWT_SECRET =
          'auth-be01-live-authority-test-secret';

        const latestChange =
          await prisma
            .syncChangeLog
            .findFirst({
              orderBy: {
                id:
                  'desc',
              },

              select: {
                id:
                  true,
              },
            });

        baselineCursor =
          latestChange
            ?.id
            .toString() ??
          '0';

        await prisma
          .organization
          .create({
            data: {
              id:
                organizationAId,

              name:
                `AUTH-BE-01 Org A ${runId}`,
            },
          });

        await prisma
          .organization
          .create({
            data: {
              id:
                organizationBId,

              name:
                `AUTH-BE-01 Org B ${runId}`,
            },
          });

        await prisma
          .user
          .create({
            data: {
              id:
                professionalUserId,

              name:
                'AUTH-BE-01 Professional',

              email:
                `auth-be01-pro-${runId}@assistailab.test`,

              passwordHash:
                'not-used',

              role:
                Role.ADMIN,

              status:
                UserStatus.ACTIVE,

              customerId:
                null,
            },
          });

        /**
         * Create Org-A first on purpose.
         * The token below will target Org-B.
         */
        await prisma
          .membership
          .create({
            data: {
              userId:
                professionalUserId,

              organizationId:
                organizationAId,

              role:
                Role.ADMIN,
            },
          });

        await prisma
          .membership
          .create({
            data: {
              userId:
                professionalUserId,

              organizationId:
                organizationBId,

              role:
                Role.TECHNICIAN,
            },
          });

        await prisma
          .customer
          .createMany({
            data: [
              {
                id:
                  customerAId,

                name:
                  'AUTH-BE-01 Customer A',

                email:
                  `auth-be01-customer-a-${runId}@assistailab.test`,
              },
              {
                id:
                  customerBId,

                name:
                  'AUTH-BE-01 Customer B',

                email:
                  `auth-be01-customer-b-${runId}@assistailab.test`,
              },
              {
                id:
                  syncCustomerId,

                name:
                  'AUTH-BE-01 Sync Customer',

                email:
                  `auth-be01-sync-${runId}@assistailab.test`,
              },
            ],
          });

        await prisma
          .user
          .create({
            data: {
              id:
                customerUserId,

              name:
                'AUTH-BE-01 Customer',

              email:
                `auth-be01-user-customer-${runId}@assistailab.test`,

              passwordHash:
                'not-used',

              role:
                Role.CUSTOMER,

              status:
                UserStatus.ACTIVE,

              customerId:
                customerAId,
            },
          });

        await prisma
          .customerOrganization
          .createMany({
            data: [
              /**
               * CUSTOMER authentication is global and must remain valid even
               * when the Customer is linked to multiple organizations.
               */
              {
                customerId:
                  customerAId,

                organizationId:
                  organizationAId,

                status:
                  CustomerOrganizationStatus.ACTIVE,
              },
              {
                customerId:
                  customerAId,

                organizationId:
                  organizationBId,

                status:
                  CustomerOrganizationStatus.ACTIVE,
              },
              {
                customerId:
                  syncCustomerId,

                organizationId:
                  organizationAId,

                status:
                  CustomerOrganizationStatus.ACTIVE,
              },
              {
                customerId:
                  syncCustomerId,

                organizationId:
                  organizationBId,

                status:
                  CustomerOrganizationStatus.ACTIVE,
              },
            ],
          });

        await prisma
          .equipment
          .createMany({
            data: [
              {
                id:
                  syncEquipmentAId,

                customerId:
                  syncCustomerId,

                ownerType:
                  EquipmentOwnerType.CUSTOMER,

                brand:
                  'AUTH-BE-01',

                model:
                  'A',

                type:
                  'NOTEBOOK',
              },
              {
                id:
                  syncEquipmentBId,

                customerId:
                  syncCustomerId,

                ownerType:
                  EquipmentOwnerType.CUSTOMER,

                brand:
                  'AUTH-BE-01',

                model:
                  'B',

                type:
                  'NOTEBOOK',
              },
            ],
          });

        await prisma
          .serviceOrder
          .createMany({
            data: [
              {
                id:
                  syncOrderAId,

                organizationId:
                  organizationAId,

                customerId:
                  syncCustomerId,

                equipmentId:
                  syncEquipmentAId,

                problemDescription:
                  'AUTH-BE-01 Sync Org A',
              },
              {
                id:
                  syncOrderBId,

                organizationId:
                  organizationBId,

                customerId:
                  syncCustomerId,

                equipmentId:
                  syncEquipmentBId,

                problemDescription:
                  'AUTH-BE-01 Sync Org B',
              },
            ],
          });

        await prisma
          .syncChangeLog
          .createMany({
            data: [
              {
                cursor:
                  randomUUID(),

                entityType:
                  'SERVICE_ORDER',

                entityId:
                  syncOrderAId,

                operationType:
                  OperationType.CREATE,

                data: {
                  id:
                    syncOrderAId,

                  organizationId:
                    organizationAId,

                  customerId:
                    syncCustomerId,
                },
              },
              {
                cursor:
                  randomUUID(),

                entityType:
                  'SERVICE_ORDER',

                entityId:
                  syncOrderBId,

                operationType:
                  OperationType.CREATE,

                data: {
                  id:
                    syncOrderBId,

                  organizationId:
                    organizationBId,

                  customerId:
                    syncCustomerId,
                },
              },
            ],
          });

        app =
          buildApp();

        app.get(
          '/__auth-be01/admin-only',
          {
            preValidation: [
              (app as any)
                .authenticate,

              (app as any)
                .authorize([
                  'ADMIN',
                ]),
            ],
          },
          async () => ({
            ok:
              true,
          })
        );

        await app.ready();
      }
    );

    after(
      async () => {
        await app.close();

        await prisma
          .syncChangeLog
          .deleteMany({
            where: {
              entityId: {
                in: [
                  syncOrderAId,
                  syncOrderBId,
                ],
              },
            },
          });

        await prisma
          .serviceOrder
          .deleteMany({
            where: {
              id: {
                in: [
                  syncOrderAId,
                  syncOrderBId,
                ],
              },
            },
          });

        await prisma
          .equipment
          .deleteMany({
            where: {
              id: {
                in: [
                  syncEquipmentAId,
                  syncEquipmentBId,
                ],
              },
            },
          });

        await prisma
          .customerOrganization
          .deleteMany({
            where: {
              customerId: {
                in: [
                  customerAId,
                  syncCustomerId,
                ],
              },
            },
          });

        await prisma
          .membership
          .deleteMany({
            where: {
              userId:
                professionalUserId,
            },
          });

        await prisma
          .user
          .deleteMany({
            where: {
              id: {
                in: [
                  professionalUserId,
                  customerUserId,
                ],
              },
            },
          });

        await prisma
          .customer
          .deleteMany({
            where: {
              id: {
                in: [
                  customerAId,
                  customerBId,
                  syncCustomerId,
                ],
              },
            },
          });

        await prisma
          .organization
          .deleteMany({
            where: {
              id: {
                in: [
                  organizationAId,
                  organizationBId,
                ],
              },
            },
          });

        if (
          previousJwtSecret
        ) {
          process.env.JWT_SECRET =
            previousJwtSecret;
        } else {
          delete process.env
            .JWT_SECRET;
        }
      }
    );

    test(
      '/auth/me preserves exact JWT-bound Org-B scope even when Org-A Membership is older',
      async () => {
        const response =
          await getMe(
            professionalToken(
              'TECHNICIAN',
              organizationBId
            )
          );

        assert.equal(
          response.statusCode,
          200
        );

        const body =
          response.json();

        assert.equal(
          body.user.organizationId,
          organizationBId
        );

        assert.equal(
          body.user.role,
          Role.TECHNICIAN
        );

        /**
         * memberships[] remains informational and may contain every
         * professional Membership. Security authority MUST still remain
         * bound to the exact JWT scope asserted above.
         */
        assert.equal(
          body.user.memberships.length,
          2
        );

        const membershipsByOrganization =
          new Map(
            body.user.memberships.map(
              (
                membership: {
                  organizationId:
                    string;

                  role:
                    Role;
                }
              ) => [
                membership.organizationId,
                membership.role,
              ]
            )
          );

        assert.equal(
          membershipsByOrganization.get(
            organizationAId
          ),
          Role.ADMIN
        );

        assert.equal(
          membershipsByOrganization.get(
            organizationBId
          ),
          Role.TECHNICIAN
        );
      }
    );

    test(
      'removed exact Membership invalidates current credential even when another Membership remains',
      async () => {
        await prisma
          .membership
          .delete({
            where: {
              userId_organizationId: {
                userId:
                  professionalUserId,

                organizationId:
                  organizationBId,
              },
            },
          });

        try {
          const response =
            await getMe(
              professionalToken(
                'TECHNICIAN',
                organizationBId
              )
            );

          assert.equal(
            response.statusCode,
            403
          );

          assert.deepEqual(
            response.json(),
            {
              error:
                'AUTHORITY_REAUTH_REQUIRED',
            }
          );
        } finally {
          await prisma
            .membership
            .create({
              data: {
                userId:
                  professionalUserId,

                organizationId:
                  organizationBId,

                role:
                  Role.TECHNICIAN,
              },
            });
        }
      }
    );

    test(
      'live role elevation does not silently elevate an old TECHNICIAN token',
      async () => {
        await prisma
          .membership
          .update({
            where: {
              userId_organizationId: {
                userId:
                  professionalUserId,

                organizationId:
                  organizationBId,
              },
            },

            data: {
              role:
                Role.ADMIN,
            },
          });

        try {
          const response =
            await getMe(
              professionalToken(
                'TECHNICIAN',
                organizationBId
              )
            );

          assert.equal(
            response.statusCode,
            403
          );

          assert.equal(
            response.json().error,
            'AUTHORITY_REAUTH_REQUIRED'
          );
        } finally {
          await prisma
            .membership
            .update({
              where: {
                userId_organizationId: {
                  userId:
                    professionalUserId,

                  organizationId:
                    organizationBId,
                },
              },

              data: {
                role:
                  Role.TECHNICIAN,
              },
            });
        }
      }
    );

    test(
      'live role downgrade does not silently downgrade an old ADMIN token',
      async () => {
        await prisma
          .membership
          .update({
            where: {
              userId_organizationId: {
                userId:
                  professionalUserId,

                organizationId:
                  organizationAId,
              },
            },

            data: {
              role:
                Role.TECHNICIAN,
            },
          });

        try {
          const response =
            await getMe(
              professionalToken(
                'ADMIN',
                organizationAId
              )
            );

          assert.equal(
            response.statusCode,
            403
          );

          assert.equal(
            response.json().error,
            'AUTHORITY_REAUTH_REQUIRED'
          );
        } finally {
          await prisma
            .membership
            .update({
              where: {
                userId_organizationId: {
                  userId:
                    professionalUserId,

                  organizationId:
                    organizationAId,
                },
              },

              data: {
                role:
                  Role.ADMIN,
              },
            });
        }
      }
    );

    test(
      'non-ACTIVE professional User is revoked immediately',
      async () => {
        try {
          for (
            const status of [
              UserStatus.PENDING,
              UserStatus.SUSPENDED,
              UserStatus.DISABLED,
            ]
          ) {
            await prisma
              .user
              .update({
                where: {
                  id:
                    professionalUserId,
                },

                data: {
                  status,
                },
              });

            const response =
              await getMe(
                professionalToken(
                  'TECHNICIAN',
                  organizationBId
                )
              );

            assert.equal(
              response.statusCode,
              403
            );

            assert.equal(
              response.json().error,
              'AUTHORITY_REAUTH_REQUIRED'
            );
          }
        } finally {
          await prisma
            .user
            .update({
              where: {
                id:
                  professionalUserId,
              },

              data: {
                status:
                  UserStatus.ACTIVE,
              },
            });
        }
      }
    );

    test(
      'CUSTOMER token requires exact live User.customerId coherence',
      async () => {
        const valid =
          await getMe(
            customerToken()
          );

        assert.equal(
          valid.statusCode,
          200
        );

        await prisma
          .user
          .update({
            where: {
              id:
                customerUserId,
            },

            data: {
              customerId:
                customerBId,
            },
          });

        try {
          const stale =
            await getMe(
              customerToken()
            );

          assert.equal(
            stale.statusCode,
            403
          );

          assert.equal(
            stale.json().error,
            'AUTHORITY_REAUTH_REQUIRED'
          );
        } finally {
          await prisma
            .user
            .update({
              where: {
                id:
                  customerUserId,
              },

              data: {
                customerId:
                  customerAId,
              },
            });
        }
      }
    );

    test(
      'CUSTOMER live identity-class change invalidates the issued credential',
      async () => {
        await prisma
          .user
          .update({
            where: {
              id:
                customerUserId,
            },

            data: {
              role:
                Role.TECHNICIAN,
            },
          });

        try {
          const response =
            await getMe(
              customerToken()
            );

          assert.equal(
            response.statusCode,
            403
          );

          assert.equal(
            response.json().error,
            'AUTHORITY_REAUTH_REQUIRED'
          );
        } finally {
          await prisma
            .user
            .update({
              where: {
                id:
                  customerUserId,
              },

              data: {
                role:
                  Role.CUSTOMER,
              },
            });
        }
      }
    );

    test(
      'structurally impossible authority claims are rejected with 401',
      async () => {
        const invalidTokens = [
          app.jwt.sign({
            sub:
              professionalUserId,

            role:
              'TECHNICIAN',

            name:
              'Invalid Professional',

            customerId:
              null,

            organizationId:
              null,
          }),

          app.jwt.sign({
            sub:
              professionalUserId,

            role:
              'TECHNICIAN',

            name:
              'Invalid Professional',

            customerId:
              customerAId,

            organizationId:
              organizationBId,
          }),

          app.jwt.sign({
            sub:
              professionalUserId,

            role:
              'UNKNOWN_ROLE',

            name:
              'Invalid Professional',

            customerId:
              null,

            organizationId:
              organizationBId,
          }),

          app.jwt.sign({
            sub:
              customerUserId,

            role:
              'CUSTOMER',

            name:
              'Invalid Customer',

            customerId:
              customerAId,

            organizationId:
              organizationAId,
          }),

          app.jwt.sign({
            sub:
              customerUserId,

            role:
              'CUSTOMER',

            name:
              'Invalid Customer',

            customerId:
              null,

            organizationId:
              null,
          }),
        ];

        for (
          const token of
            invalidTokens
        ) {
          const response =
            await getMe(
              token
            );

          assert.equal(
            response.statusCode,
            401
          );

          assert.deepEqual(
            response.json(),
            {
              error:
                'Unauthorized',
            }
          );
        }
      }
    );

    test(
      'valid principal without endpoint role receives ordinary insufficient-privileges 403',
      async () => {
        const response =
          await app.inject({
            method:
              'GET',

            url:
              '/__auth-be01/admin-only',

            headers: {
              authorization:
                `Bearer ${professionalToken(
                  'TECHNICIAN',
                  organizationBId
                )}`,
            },
          });

        assert.equal(
          response.statusCode,
          403
        );

        assert.deepEqual(
          response.json(),
          {
            error:
              'Forbidden: Insufficient privileges',
          }
        );
      }
    );

    test(
      'professional Sync remains bound to validated JWT organization and never falls back to older Membership',
      async () => {
        const token =
          professionalToken(
            'TECHNICIAN',
            organizationBId
          );

        const response =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/sync/changes?cursor=${baselineCursor}&limit=100`,

            headers: {
              authorization:
                `Bearer ${token}`,
            },
          });

        assert.equal(
          response.statusCode,
          200
        );

        const body =
          response.json();

        const receivedIds =
          new Set<string>(
            body.changes.map(
              (
                change: {
                  entityId:
                    string;
                }
              ) =>
                change.entityId
            )
          );

        assert.equal(
          receivedIds.has(
            syncOrderBId
          ),
          true
        );

        assert.equal(
          receivedIds.has(
            syncOrderAId
          ),
          false
        );
      }
    );

    test(
      'professional Sync rejects a stale Org-B token after exact Membership removal and never falls back to Org-A',
      async () => {
        await prisma
          .membership
          .delete({
            where: {
              userId_organizationId: {
                userId:
                  professionalUserId,

                organizationId:
                  organizationBId,
              },
            },
          });

        try {
          const response =
            await app.inject({
              method:
                'GET',

              url:
                `/api/v1/sync/changes?cursor=${baselineCursor}&limit=100`,

              headers: {
                authorization:
                  `Bearer ${professionalToken(
                    'TECHNICIAN',
                    organizationBId
                  )}`,
              },
            });

          assert.equal(
            response.statusCode,
            403
          );

          assert.deepEqual(
            response.json(),
            {
              error:
                'AUTHORITY_REAUTH_REQUIRED',
            }
          );
        } finally {
          await prisma
            .membership
            .create({
              data: {
                userId:
                  professionalUserId,

                organizationId:
                  organizationBId,

                role:
                  Role.TECHNICIAN,
              },
            });
        }
      }
    );

    test(
      'deleted live User revokes an otherwise valid JWT',
      async () => {
        const temporaryUserId =
          randomUUID();

        const temporaryEmail =
          `auth-be01-deleted-${runId}@assistailab.test`;

        await prisma
          .user
          .create({
            data: {
              id:
                temporaryUserId,

              name:
                'AUTH-BE-01 Deleted User',

              email:
                temporaryEmail,

              passwordHash:
                'not-used',

              role:
                Role.TECHNICIAN,

              status:
                UserStatus.ACTIVE,
            },
          });

        await prisma
          .membership
          .create({
            data: {
              userId:
                temporaryUserId,

              organizationId:
                organizationBId,

              role:
                Role.TECHNICIAN,
            },
          });

        const token =
          app.jwt.sign({
            sub:
              temporaryUserId,

            role:
              'TECHNICIAN',

            name:
              'AUTH-BE-01 Deleted User',

            customerId:
              null,

            organizationId:
              organizationBId,
          });

        await prisma
          .user
          .delete({
            where: {
              id:
                temporaryUserId,
            },
          });

        const response =
          await getMe(
            token
          );

        assert.equal(
          response.statusCode,
          403
        );

        assert.equal(
          response.json().error,
          'AUTHORITY_REAUTH_REQUIRED'
        );
      }
    );
  }
);
