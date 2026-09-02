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

  /**
   * FIN-F02 Phase 1A:
   *
   * Keep the new state structurally represented without
   * prematurely opening the protected reapproval edge.
   *
   * AGUARDANDO_REAPROVACAO -> EM_EXECUCAO will only be
   * introduced together with the dedicated quote-decision
   * command and generic-status edge protection.
   */
  AGUARDANDO_REAPROVACAO: [
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

/**
 * FIN-F02 protected state edges.
 *
 * These transitions may exist in the domain state machine,
 * but generic PATCH/Sync writers are never authoritative for them.
 */
export function isFinanceCommandOnlyStatusTransition(
  currentStatus: ServiceOrderStatus,
  newStatus: ServiceOrderStatus
): boolean {
  return (
    (
      currentStatus ===
        ServiceOrderStatus.DIAGNOSTICO &&
      newStatus ===
        ServiceOrderStatus.AGUARDANDO_APROVACAO
    ) ||
    (
      currentStatus ===
        ServiceOrderStatus.AGUARDANDO_APROVACAO &&
      newStatus ===
        ServiceOrderStatus.EM_EXECUCAO
    ) ||
    (
      currentStatus ===
        ServiceOrderStatus.EM_EXECUCAO &&
      newStatus ===
        ServiceOrderStatus.AGUARDANDO_REAPROVACAO
    ) ||
    (
      currentStatus ===
        ServiceOrderStatus.AGUARDANDO_REAPROVACAO &&
      newStatus ===
        ServiceOrderStatus.EM_EXECUCAO
    ) ||
    (
      currentStatus ===
        ServiceOrderStatus.EM_EXECUCAO &&
      newStatus ===
        ServiceOrderStatus.PRONTO
    )
  );
}

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