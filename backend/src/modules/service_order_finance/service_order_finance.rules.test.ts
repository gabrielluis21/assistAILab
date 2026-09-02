import test from 'node:test';
import assert from 'node:assert/strict';

import {
  ServiceOrderStatus,
} from '@prisma/client';

import {
  isFinanceCommandOnlyStatusTransition,
} from '../service_orders/service_order_state_machine.js';

test(
  'FIN-F02 protects all frozen finance command status edges',
  () => {
    const protectedEdges = [
      [
        ServiceOrderStatus
          .DIAGNOSTICO,
        ServiceOrderStatus
          .AGUARDANDO_APROVACAO,
      ],
      [
        ServiceOrderStatus
          .AGUARDANDO_APROVACAO,
        ServiceOrderStatus
          .EM_EXECUCAO,
      ],
      [
        ServiceOrderStatus
          .EM_EXECUCAO,
        ServiceOrderStatus
          .AGUARDANDO_REAPROVACAO,
      ],
      [
        ServiceOrderStatus
          .AGUARDANDO_REAPROVACAO,
        ServiceOrderStatus
          .EM_EXECUCAO,
      ],
      [
        ServiceOrderStatus
          .EM_EXECUCAO,
        ServiceOrderStatus
          .PRONTO,
      ],
    ] as const;

    for (
      const [
        from,
        to,
      ] of
      protectedEdges
    ) {
      assert.equal(
        isFinanceCommandOnlyStatusTransition(
          from,
          to
        ),
        true,
        `${from} -> ${to}`
      );
    }
  }
);

test(
  'FIN-F02 does not classify ordinary cancellation as a finance command edge',
  () => {
    assert.equal(
      isFinanceCommandOnlyStatusTransition(
        ServiceOrderStatus
          .DIAGNOSTICO,
        ServiceOrderStatus
          .CANCELADO
      ),
      false
    );
  }
);
