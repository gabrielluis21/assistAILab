import {
  QuoteDecision,
  ServiceOrderStatus,
} from '@prisma/client';

export type CustomerQuoteDecisionPlan = {
  previousStatus:
    ServiceOrderStatus;

  nextStatus:
    ServiceOrderStatus;

  changesServiceOrder:
    boolean;

  setLastApprovedToCurrent:
    boolean;

  initialRejection:
    boolean;
};

/**
 * Frozen FIN-F02 customer decision semantics:
 *
 * INITIAL APPROVE:
 * AGUARDANDO_APROVACAO -> EM_EXECUCAO.
 *
 * INITIAL REJECT:
 * AGUARDANDO_APROVACAO -> CANCELADO.
 *
 * REAPPROVAL APPROVE:
 * AGUARDANDO_REAPROVACAO -> EM_EXECUCAO.
 *
 * REAPPROVAL REJECT:
 * decision persists, current rejected revision remains current,
 * lastApproved remains untouched and the OS stays
 * AGUARDANDO_REAPROVACAO until staff explicitly resumes the
 * prior approved scope or cancels/intervenes operationally.
 */
export function deriveCustomerQuoteDecisionPlan(
  currentStatus:
    ServiceOrderStatus,
  decision:
    QuoteDecision
): CustomerQuoteDecisionPlan | null {
  if (
    currentStatus ===
    ServiceOrderStatus
      .AGUARDANDO_APROVACAO
  ) {
    if (
      decision ===
      QuoteDecision.APPROVE
    ) {
      return {
        previousStatus:
          currentStatus,
        nextStatus:
          ServiceOrderStatus
            .EM_EXECUCAO,
        changesServiceOrder:
          true,
        setLastApprovedToCurrent:
          true,
        initialRejection:
          false,
      };
    }

    return {
      previousStatus:
        currentStatus,
      nextStatus:
        ServiceOrderStatus
          .CANCELADO,
      changesServiceOrder:
        true,
      setLastApprovedToCurrent:
        false,
      initialRejection:
        true,
    };
  }

  if (
    currentStatus ===
    ServiceOrderStatus
      .AGUARDANDO_REAPROVACAO
  ) {
    if (
      decision ===
      QuoteDecision.APPROVE
    ) {
      return {
        previousStatus:
          currentStatus,
        nextStatus:
          ServiceOrderStatus
            .EM_EXECUCAO,
        changesServiceOrder:
          true,
        setLastApprovedToCurrent:
          true,
        initialRejection:
          false,
      };
    }

    return {
      previousStatus:
        currentStatus,
      nextStatus:
        currentStatus,
      changesServiceOrder:
        false,
      setLastApprovedToCurrent:
        false,
      initialRejection:
        false,
    };
  }

  return null;
}
