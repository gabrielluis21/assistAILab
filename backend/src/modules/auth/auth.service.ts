import bcrypt from 'bcrypt';
import { prisma } from '../../core/database/prisma.js';
import { RegisterInput, LoginInput } from './auth.schema.js';
import { ConflictError, UnauthorizedError, ForbiddenError } from '../../core/utils/errors.js';

const SALT_ROUNDS = 12;

export class AuthService {
  async register(input: RegisterInput) {
    const existing = await prisma.user.findUnique({ where: { email: input.email } });
    if (existing) throw new ConflictError('Email already registered');

    const passwordHash = await bcrypt.hash(input.password, SALT_ROUNDS);

    // Resolve customerId for CUSTOMER role
    let resolvedCustomerId: string | null = null;
    if (input.role === 'CUSTOMER') {
      if (input.customerId) {
        // Validate that the provided customerId actually exists
        const customerExists = await prisma.customer.findUnique({ where: { id: input.customerId } });
        if (!customerExists) {
          throw new ForbiddenError('Provided customerId does not reference a valid Customer record');
        }
        // Ensure no other user is already linked to this customer
        const alreadyLinked = await prisma.user.findUnique({ where: { customerId: input.customerId } });
        if (alreadyLinked) {
          throw new ConflictError('A user account is already linked to this Customer');
        }
        resolvedCustomerId = input.customerId;
      } else {
        // Auto-provision a Customer record for this CUSTOMER user
        // PENDING: Admin-controlled customer creation flow is not yet defined.
        // For now, we provision a minimal Customer using name and email from registration.
        const newCustomer = await prisma.customer.create({
          data: {
            name: input.name,
            email: input.email,
          },
        });
        resolvedCustomerId = newCustomer.id;
      }
    }

    const user = await prisma.user.create({
      data: {
        name: input.name,
        email: input.email,
        passwordHash,
        role: input.role,
        customerId: resolvedCustomerId,
      },
      select: { id: true, name: true, email: true, role: true, customerId: true, createdAt: true },
    });

    return user;
  }

  async validateCredentials(input: LoginInput) {
    const user = await prisma.user.findUnique({ where: { email: input.email } });
    if (!user) throw new UnauthorizedError('Invalid credentials');

    const valid = await bcrypt.compare(input.password, user.passwordHash);
    if (!valid) throw new UnauthorizedError('Invalid credentials');

    return { id: user.id, name: user.name, email: user.email, role: user.role, customerId: user.customerId };
  }
}
