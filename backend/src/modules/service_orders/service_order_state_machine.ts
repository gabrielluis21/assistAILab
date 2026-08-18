import { ServiceOrderStatus } from '@prisma/client';

export const ALLOWED_TRANSITIONS: Record<
  ServiceOrderStatus,
  ServiceOrderStatus[]
> = {
  DRAFT: [
    ServiceOrderStatus.DIAGNOSTICO,
    ServiceOrderStatus.CANCELADO,
  ],

  DIAGNOSTICO: [
    ServiceOrderStatus.AGUARDANDO_APROVACAO,
    ServiceOrderStatus.CANCELADO,
  ],

  AGUARDANDO_APROVACAO: [
    ServiceOrderStatus.EM_EXECUCAO,
    ServiceOrderStatus.CANCELADO,
  ],

  EM_EXECUCAO: [
    ServiceOrderStatus.PRONTO,
    ServiceOrderStatus.CANCELADO,
  ],

  PRONTO: [
    ServiceOrderStatus.ENTREGUE,
    ServiceOrderStatus.CANCELADO,
  ],

  ENTREGUE: [],

  CANCELADO: [],
};

export function isValidStatusTransition(
  currentStatus:
    | ServiceOrderStatus
    | null
    | undefined,
  newStatus: ServiceOrderStatus
): boolean {
  if (!currentStatus) {
    return true;
  }

  if (currentStatus === newStatus) {
    return true;
  }

  const allowed =
    ALLOWED_TRANSITIONS[currentStatus] || [];

  return allowed.includes(newStatus);
}