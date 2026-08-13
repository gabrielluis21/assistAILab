import { prisma } from '../../core/database/prisma.js';
import { CreatePaymentInput, UpdatePaymentStatusInput } from './payments.schema.js';
import { NotFoundError, ConflictError } from '../../core/utils/errors.js';

export class PaymentsService {
  async listAll(serviceOrderId?: string, customerId?: string) {
    return prisma.payment.findMany({
      where: {
        ...(serviceOrderId ? { serviceOrderId } : {}),
        ...(customerId ? { customerId } : {}),
      },
      orderBy: { createdAt: 'desc' },
      include: {
        customer: { select: { id: true, name: true } },
      },
    });
  }

  async findById(id: string) {
    const payment = await prisma.payment.findUnique({
      where: { id },
      include: { customer: { select: { id: true, name: true } } },
    });
    if (!payment) throw new NotFoundError(`Payment ${id} not found`);
    return payment;
  }

  async create(data: CreatePaymentInput, operationId: string) {
    // Idempotency check
    const existing = await prisma.payment.findUnique({ where: { id: data.id } });
    if (existing) return existing; // Already processed – return existing

    return prisma.payment.create({
      data: {
        id: data.id,
        serviceOrderId: data.serviceOrderId,
        customerId: data.customerId,
        amount: data.amount,
        method: data.method,
        status: 'PENDING',
        notes: data.notes,
      },
    });
  }

  async updateStatus(id: string, data: UpdatePaymentStatusInput) {
    const existing = await prisma.payment.findUnique({ where: { id } });
    if (!existing) throw new NotFoundError(`Payment ${id} not found`);

    // Business rules: can only confirm/cancel PENDING payments
    if (existing.status !== 'PENDING' && data.status !== 'REFUNDED') {
      throw new ConflictError(`Cannot update payment in status ${existing.status} to ${data.status}`);
    }

    return prisma.payment.update({
      where: { id },
      data: {
        status: data.status,
        paidAt: data.status === 'CONFIRMED' ? (data.paidAt ? new Date(data.paidAt) : new Date()) : null,
        updatedAt: new Date(),
      },
    });
  }

  async getRevenueSummary() {
    const now = new Date();
    const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1);

    const [totalRevenue, monthRevenue, pending] = await Promise.all([
      prisma.payment.aggregate({
        where: { status: 'CONFIRMED' },
        _sum: { amount: true },
      }),
      prisma.payment.aggregate({
        where: { status: 'CONFIRMED', paidAt: { gte: startOfMonth } },
        _sum: { amount: true },
      }),
      prisma.payment.aggregate({
        where: { status: 'PENDING' },
        _sum: { amount: true },
        _count: true,
      }),
    ]);

    return {
      totalRevenue: totalRevenue._sum.amount ?? 0,
      monthRevenue: monthRevenue._sum.amount ?? 0,
      pendingAmount: pending._sum.amount ?? 0,
      pendingCount: pending._count,
    };
  }
}
