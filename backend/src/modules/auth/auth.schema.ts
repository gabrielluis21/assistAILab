import {
  z,
} from 'zod';

export const registerSchema =
  z.object({
    name:
      z.string()
        .min(2)
        .max(120),

    email:
      z.string()
        .email()
        .max(191),

    password:
      z.string()
        .min(8)
        .max(128),

    phone:
      z.string()
        .max(20)
        .optional(),
  });

export const loginSchema =
  z.object({
    email:
      z.string()
        .email(),

    password:
      z.string()
        .min(1),
  });

/**
 * O client fornece apenas:
 *
 * - token recebido no QR/link;
 * - senha que deseja definir.
 *
 * customerId, organizationId e role
 * NUNCA vêm do client.
 */
export const claimCustomerOnboardingSchema =
  z.object({
    token:
      z.string()
        .trim()
        .min(32),

    password:
      z.string()
        .min(8)
        .max(128),
  });

export type RegisterInput =
  z.infer<
    typeof registerSchema
  >;

export type LoginInput =
  z.infer<
    typeof loginSchema
  >;

export type ClaimCustomerOnboardingInput =
  z.infer<
    typeof claimCustomerOnboardingSchema
  >;