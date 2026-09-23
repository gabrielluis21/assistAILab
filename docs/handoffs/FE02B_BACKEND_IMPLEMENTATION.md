# FE-02B Backend/Sync — candidate de implementação

Baseline: `dd92e714919323a29d39296e0291efcd8f051cd3`.
Human GO explícito recebido em 15/09/2026, após Cyber Final Architecture Pass R2.
Escopo: Backend/Sync; nenhum arquivo Flutter, schema Prisma ou migration alterado.
FE-03, FE-04 e SEC-PART-TENANCY-01 permanecem fora desta entrega.

## Contrato entregue ao Frontend

| Superfície | Contrato |
| --- | --- |
| `POST /api/v1/sync/bootstrap` | `{contractVersion:2, limit?:1..100, continuationToken?:string}`. JWT obrigatório em todas as páginas. |
| Resposta de bootstrap | `contractVersion`, `bootstrapCursor`, `records:[{entityType,entityId,data}]`, `complete`, `continuationToken`, `bootstrapProof`. Prova somente na página final. |
| `POST /api/v1/sync/push` | `{contractVersion:1\|2, entries:[...]}`. Ausência da versão significa v1. V2 exige `X-Sync-Bootstrap-Proof`, além do JWT. |
| `GET /api/v1/sync/changes` | `contractVersion`, `cursor`, `limit`. V2 exige prova e cursor >= fronteira do bootstrap. |
| `GET /api/v1/service-orders/:id/projection` | Agregado canônico v2 completo, profissional ou CUSTOMER conforme autorização autenticada. Usar após comandos dedicados de orçamento. |

V2 SERVICE_ORDER transporta `projectionRevision`, OS, `diagnosis`, `totalAmountMinor`, coleção completa `items`, `currentQuoteRevisionId`, `lastApprovedQuoteRevisionId`, `materializedQuoteRevisionId` e `commercialScopeSource`. Não transporta `financeCoreVersion`. CUSTOMER tem serializer explícito sem identidade profissional, joins de catálogo, entidades financeiras, auditoria ou snapshot bruto de QuoteRevision.

Os comandos dedicados existentes mantêm suas respostas idempotentes históricas. Após sucesso, buscar `/projection` para obter o estado comercial atual. Não usar a resposta antiga como substituta do agregado canônico.

Exemplo de entrada monetária v2:

```json
{
  "contractVersion": 2,
  "entries": [{
    "operationId": "UUID",
    "entityType": "SERVICE_ORDER_ITEM",
    "entityId": "UUID",
    "operationType": "CREATE",
    "createdAt": "2026-09-15T15:00:00Z",
    "payload": {
      "serviceOrderId": "UUID",
      "description": "Mão de obra",
      "quantity": 2,
      "unitPriceMinor": 1234
    }
  }]
}
```

`unitPriceMinor` e quantidade são entradas; totais de linha e OS são sempre derivados. CREATE exige preço e quantidade. UPDATE não cria, não muda o pai e preserva campos omitidos. Publicação impede escrita comercial genérica. CUSTOMER usa comandos dedicados para decisões; Generic Sync não concede escrita comercial.

V1 aceita dinheiro major numérico ou textual somente quando `String(value)` possui representação decimal simples exata com até duas casas. Os totais legados são assertions. No Pull v1, valores major são texto decimal exato; o cliente legado persiste-os pela afinidade REAL existente, sem adquirir nova autoridade. A migração Flutter deve abandonar essa representação local. Aliases ambíguos, ruído IEEE-754, negativos, overflow e missing obrigatório falham. Novos snapshots internos de orçamento são v2 com `parts:[]`; snapshots/hash v1 existentes permanecem intactos.

PART Push/Pull fica bloqueado em ambas as versões. Nenhuma associação global nova ou diferente é aceita em itens/commercial revision. `partId` histórico omitido no UPDATE é preservado; conservar o identificador não autoriza consulta ao catálogo.

## Aplicação local obrigatória

1. Preparar todas as páginas do bootstrap sem publicar estado parcial; usar apenas continuações devolvidas pelo servidor, mantendo `limit` e AuthScope.
2. Na página final, aplicar todas as projeções, remoções, contrato, prova e cursor H em uma transação SQLite. Preservar Outbox para reconciliação.
3. Iniciar Pull `> H`; não converter cursor v1 ou cursor zero em ativação v2.
4. Aplicar OS + diagnóstico + total + coleção completa dos itens + cursor atomicamente. Eventos de item v2 são convertidos pelo Backend em agregado do pai.
5. Parser Flutter de `projectionRevision`: apenas `0|[1-9][0-9]*`, depois `BigInt.parse`. Maior aplica, menor descarta; igual exige igualdade canônica de TODOS os campos autoritativos, incluindo campos da OS. Nunca Number/double/int64 presumido/comparação lexical.
6. `SYNC_V2_REFRESH_REQUIRED` não avança cursor: novo bootstrap, preservando intents. Não reemitir PAYMENT como Generic Push, trocar operationId ou reinterpretar intents incertas para destravar.

## Garantias e escolhas de implementação

- Cálculo monetário em BigInt/inteiros minor validados; Decimal recebe texto exato. Tetos DECIMAL(10,2), DECIMAL(14,2), quantidade Int32 e limite menor do comando comercial preservados.
- Publicação inicial recalcula linhas e total, valida positividade e persiste antes de publicar a revisão imutável.
- Materialização exige igualdade semântica com revisão validada por hash/identidade/agregado; não é inferida do status. Retomada preserva ponteiro da revisão rejeitada.
- `syncTransaction` usa uma linha técnica identificada por cursor `__FE02B_PROJECTION_BARRIER__` na tabela EXISTENTE `sync_change_logs`. A aquisição exclusiva ocorre antes de locks de domínio e alocação de eventos. Todos os writers de projeção e financeiros do aplicativo usam essa fronteira.
- A mesma barreira protege `syncRead`, leitura completa e H. Logo não existe writer dessa versão que consiga commitar depois da captura com evento <= H. IDs auto-increment podem ter lacunas; não são timestamps nem sequência sem lacunas.
- Observação explícita das mutações dentro da transação registra CREATE/UPDATE/DELETE de entidades projetadas. Metadados de audiência/tombstones derivam de linhas e relações do banco, com HMAC vinculado à identidade inteira do evento. JSON histórico não pode fabricar evidência de exclusão.
- Pull re-hidrata a entidade atual sob autorização por tipo + ID + relações e usa a revisão da leitura atual. Nunca apresenta o JSON antigo como v2 nem associa conteúdo atual à revisão antiga do evento.
- Hash/comando de idempotência incluem versão, entidade, ID, operação e payload/assertions normalizados. Ator/escopo vêm da autenticação. Lease CAS, alteração, eventos e conclusão de sucesso são transacionais. Falhas de domínio são persistidas após rollback; falhas de infraestrutura mantêm a reserva para retry seguro. Histórico sem identidade suficiente retorna `LEGACY_OPERATION_RECONCILIATION_REQUIRED`.
- Provas e metadados usam HMAC com separação de propósito derivado de `JWT_SECRET`; prova não substitui JWT nem autorização viva. Prova de bootstrap vale 24 horas. Rotação do segredo exige novo bootstrap.

## Operação do candidate

A barreira global prioriza correção e serializa writers projetados entre tenants. Captura de bootstrap materializa somente o escopo autorizado e libera a transação antes de servir páginas. É necessário medir latência/contenção com o volume real antes de produção.

Snapshots paginados ficam em memória por 5 minutos, com limite de 16 MiB por snapshot e 64 MiB por processo; exceder capacidade retorna erro explícito, nunca truncamento/ativação parcial. Um novo bootstrap do mesmo escopo substitui o anterior. Usar afinidade de worker durante a paginação. Perda do worker/expiração requer reinício do bootstrap. A prova final continua verificável entre workers com o mesmo segredo.

Cutover deve drenar writers da versão anterior antes de ativar v2. Não manter implantação mista: escritores antigos não participam da barreira. Jobs/importações futuros que modifiquem projeções precisam usar `syncTransaction`. A linha técnica da barreira não pode ser removida por manutenção de ChangeLog. Esta entrega não executa deploy nem altera banco de produção.

## Validação

- Build TypeScript: passou localmente.
- Prisma validate: passou; sem mudança de schema/migration.
- 123 testes locais de regras/segurança: passaram, incluindo 38 novos testes FE-02B.
- Gate MySQL: `sync.fe02b.integration.test.ts` e workflow `FE-02B Backend Authority Gate`, com banco descartável e migrations existentes. Não executado: MySQL local indisponível e publicação remota rejeitada pelo GitHub (`403 Resource not accessible by integration`). Não declarar concorrência ou suíte completa certificadas antes da execução deste gate.
- Ambiente local: Node 24.19.0/npm 11.9.0; workflow usa versões exigidas no baseline (Node 24.20.0/npm 11.19.0). Não foi possível provisionar MySQL local neste ambiente.

PR remoto não foi criado por falta de acesso de escrita na integração. O pacote de entrega contém patch aplicável ao baseline, relatório e workflow do gate.

Cyber Implementation Review ainda deve avaliar o candidate; aprovação arquitetural e Human GO não substituem certificação da implementação.
