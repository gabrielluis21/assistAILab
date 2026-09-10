import test from 'node:test';
import assert from 'node:assert/strict';

import {
  QuoteDecision,
  ServiceOrderStatus,
} from '@prisma/client';

import {
  deriveCustomerQuoteDecisionPlan,
} from './customer_quote_decision.rules.js';

test(
  'FIN-F02 initial APPROVE moves to execution and becomes last-approved',
  () => {
    const plan =
      deriveCustomerQuoteDecisionPlan(
        ServiceOrderStatus
          .AGUARDANDO_APROVACAO,
        QuoteDecision
          .APPROVE
      );

    assert.deepEqual(
      plan,
      {
        previousStatus:
          ServiceOrderStatus
            .AGUARDANDO_APROVACAO,

        nextStatus:
          ServiceOrderStatus
            .EM_EXECUCAO,

        changesServiceOrder:
          true,

        setLastApprovedToCurrent:
          true,

        initialRejection:
          false,
      }
    );
  }
);

test(
  'FIN-F02 initial REJECT preserves cancellation policy',
  () => {
    const plan =
      deriveCustomerQuoteDecisionPlan(
        ServiceOrderStatus
          .AGUARDANDO_APROVACAO,
        QuoteDecision
          .REJECT
      );

    assert.equal(
      plan
        ?.nextStatus,
      ServiceOrderStatus
        .CANCELADO
    );

    assert.equal(
      plan
        ?.initialRejection,
      true
    );
  }
);

test(
  'FIN-F02 reapproval APPROVE moves back to execution and replaces last-approved pointer',
  () => {
    const plan =
      deriveCustomerQuoteDecisionPlan(
        ServiceOrderStatus
          .AGUARDANDO_REAPROVACAO,
        QuoteDecision
          .APPROVE
      );

    assert.equal(
      plan
        ?.nextStatus,
      ServiceOrderStatus
        .EM_EXECUCAO
    );

    assert.equal(
      plan
        ?.setLastApprovedToCurrent,
      true
    );
  }
);

test(
  'FIN-F02 later REJECT persists decision but does not auto-resume or revoke prior approval',
  () => {
    const plan =
      deriveCustomerQuoteDecisionPlan(
        ServiceOrderStatus
          .AGUARDANDO_REAPROVACAO,
        QuoteDecision
          .REJECT
      );

    assert.equal(
      plan
        ?.changesServiceOrder,
      false
    );

    assert.equal(
      plan
        ?.nextStatus,
      ServiceOrderStatus
        .AGUARDANDO_REAPROVACAO
    );

    assert.equal(
      plan
        ?.setLastApprovedToCurrent,
      false
    );
  }
);

test(
  'FIN-F02 rejects customer quote decisions outside waiting states',
  () => {
    assert.equal(
      deriveCustomerQuoteDecisionPlan(
        ServiceOrderStatus
          .EM_EXECUCAO,
        QuoteDecision
          .APPROVE
      ),
      null
    );
  }
);
