import {
  Role,
  UserStatus,
} from '@prisma/client';

import {
  z,
} from 'zod';

import {
  prisma,
} from '../database/prisma.js';

export type ValidatedPrincipal = {
  sub: string;
  role:
    | 'ADMIN'
    | 'TECHNICIAN'
    | 'CUSTOMER';
  name: string;
  customerId:
    string | null;
  organizationId:
    string | null;
};

export class InvalidJwtAuthorityShapeError
  extends Error {
  constructor() {
    super(
      'Invalid JWT authority shape'
    );

    Object.setPrototypeOf(
      this,
      new.target.prototype
    );
  }
}

export class AuthorityReauthenticationRequiredError
  extends Error {
  constructor() {
    super(
      'AUTHORITY_REAUTH_REQUIRED'
    );

    Object.setPrototypeOf(
      this,
      new.target.prototype
    );
  }
}

const authorityClaimsSchema =
  z.object({
    sub:
      z.string().uuid(),

    role:
      z.nativeEnum(
        Role
      ),

    name:
      z.string().min(1),

    customerId:
      z.string()
        .uuid()
        .nullable(),

    organizationId:
      z.string()
        .uuid()
        .nullable(),
  })
    .passthrough()
    .superRefine(
      (
        claims,
        ctx
      ) => {
        if (
          claims.role ===
          Role.CUSTOMER
        ) {
          if (
            !claims.customerId ||
            claims.organizationId !==
              null
          ) {
            ctx.addIssue({
              code:
                z.ZodIssueCode
                  .custom,

              message:
                'CUSTOMER authority shape is invalid',
            });
          }

          return;
        }

        if (
          ![
            Role.ADMIN,
            Role.TECHNICIAN,
          ].includes(
            claims.role
          ) ||
          !claims.organizationId ||
          claims.customerId !==
            null
        ) {
          ctx.addIssue({
            code:
              z.ZodIssueCode
                .custom,

            message:
              'Professional authority shape is invalid',
          });
        }
      }
    );

export function parseJwtAuthorityClaims(
  value:
    unknown
): ValidatedPrincipal {
  const parsed =
    authorityClaimsSchema
      .safeParse(
        value
      );

  if (
    !parsed.success
  ) {
    throw new InvalidJwtAuthorityShapeError();
  }

  return {
    sub:
      parsed.data.sub,

    role:
      parsed.data.role,

    name:
      parsed.data.name,

    customerId:
      parsed.data.customerId,

    organizationId:
      parsed.data.organizationId,
  };
}

function staleAuthority():
  never {
  throw new AuthorityReauthenticationRequiredError();
}

/**
 * AUTH-BE-01
 *
 * JWT claims are an authority assertion, not a perpetual authority source.
 *
 * Live state may validate or revoke the assertion.
 * Live state must never silently rewrite tenant / role / customer identity.
 */
export async function resolveLiveAuthority(
  rawClaims:
    unknown
): Promise<ValidatedPrincipal> {
  const claims =
    parseJwtAuthorityClaims(
      rawClaims
    );

  const currentUser =
    await prisma
      .user
      .findUnique({
        where: {
          id:
            claims.sub,
        },

        select: {
          id:
            true,

          name:
            true,

          role:
            true,

          status:
            true,

          customerId:
            true,

          customer: {
            select: {
              id:
                true,
            },
          },
        },
      });

  if (
    !currentUser ||
    currentUser.status !==
      UserStatus.ACTIVE
  ) {
    staleAuthority();
  }

  if (
    claims.role ===
    Role.CUSTOMER
  ) {
    if (
      currentUser.role !==
        Role.CUSTOMER ||
      !currentUser.customerId ||
      currentUser.customerId !==
        claims.customerId ||
      !currentUser.customer ||
      currentUser.customer.id !==
        claims.customerId
    ) {
      staleAuthority();
    }

    return {
      sub:
        claims.sub,

      role:
        'CUSTOMER',

      name:
        currentUser.name,

      customerId:
        claims.customerId,

      organizationId:
        null,
    };
  }

  /**
   * Professional identity class.
   *
   * User.role is intentionally NOT required to equal the exact
   * Membership role because one professional may legitimately hold
   * different roles in different organizations.
   *
   * The User itself must still remain a professional identity and must
   * not carry a Customer binding.
   */
  if (
    currentUser.role ===
      Role.CUSTOMER ||
    currentUser.customerId !==
      null
  ) {
    staleAuthority();
  }

  const organizationId =
    claims.organizationId;

  if (
    !organizationId
  ) {
    throw new InvalidJwtAuthorityShapeError();
  }

  const membership =
    await prisma
      .membership
      .findUnique({
        where: {
          userId_organizationId: {
            userId:
              claims.sub,

            organizationId,
          },
        },

        select: {
          role:
            true,
        },
      });

  if (
    !membership ||
    membership.role !==
      claims.role
  ) {
    staleAuthority();
  }

  return {
    sub:
      claims.sub,

    role:
      claims.role,

    name:
      currentUser.name,

    customerId:
      null,

    organizationId,
  };
}
