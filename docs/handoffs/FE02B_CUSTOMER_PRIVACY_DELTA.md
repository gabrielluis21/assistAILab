# FE-02B — CUSTOMER projection privacy delta

Parent obrigatório: `ca9aa6042d74a9b9b4e3a58b3c8645ba77111b1f`.
Parent tree: `ee17894992d3374b9ae605d18f8eb61725e577eb`.

## Mudança

Somente a projeção SERVICE_ORDER v2 para CUSTOMER foi minimizada. O serializer executa commercialProjection integralmente antes de construir uma lista explícita de campos públicos. Fingerprint comercial, identidade/hash/coerência das revisões, materialização, total de linhas e agregado continuam usando os mesmos validadores internos. O DTO staff não foi alterado.

Campos CUSTOMER mantidos: contractVersion, projectionRevision, id da OS, friendlyId, equipmentId, status, problemDescription, solution, createdAt, updatedAt, diagnosis, totalAmountMinor e items. Cada item contém exclusivamente description, quantity, unitPriceMinor e totalPriceMinor.

Não são emitidos organizationId, customerId, technicianId, financeCoreVersion, ponteiros de revisão, commercialScopeSource, id interno do item, serviceOrderId, partId, data de criação do item, hash/snapshot/auditoria ou dados Finance Core. Items é a coleção de valores comerciais da projeção, sem identidade interna para escrita. Fluxos dedicados de decisão/orçamento permanecem inalterados; este DTO não substitui os contratos desses comandos.

REST /service-orders/:id/projection, bootstrap v2 e Pull v2 já usam o mesmo serializer e recebem essa correção. Não alteramos Sync v1, outros tipos de entidade, barreira transacional, H, cursores, autenticação, idempotência, schemas monetários, PART, Payment ou bootstrap proofs.

## Regressões

- Testes de regras exigem a lista exata de chaves públicas, valores minor exatos, revisões BigInt e preservação do DTO staff.
- CUSTOMER continua rejeitando total/linha inconsistente, ponteiro incoerente, hash inválido, identidade de revisão incompatível e escopo não materializado.
- Gate MySQL FE-02B ganhou três regressões HTTP: endpoint de projeção; bootstrap completo paginado; Pull incremental depois de mudança da OS. Usa OS publicada com partId histórico e revisões reais, preservando a validação interna sem expor os identificadores.
- Confere acesso negado a outro CUSTOMER e staff de outro tenant, ausência de OS alheia no bootstrap/Pull e valores comerciais exatos.
- Seed agora valida DTO CUSTOMER por schema strict no REST e no bootstrap. Compara somente os valores públicos dos itens; checa ownership no banco, sem depender de customerId exposto pelo DTO. Teste específico impede reintrodução dos campos internos no schema de demonstração.

## Evidência local

- Build TypeScript: PASS.
- `node --test dist/modules/sync/sync.fe02b.rules.test.js dist/scripts/demo_seed.test.js`: 46 testes, 46 pass, 0 fail/cancelled/skipped.
- `git diff --check`: PASS.
- MySQL FE-02B e suíte Backend completa: NÃO EXECUTADOS aqui, pois este ambiente não dispõe de MySQL nem DATABASE_URL configurado. O PASS 251/251 do parent não certifica este novo delta.
- Runtime local: Node/npm abaixo das versões exigidas pelo projeto; repetir os gates no ambiente Windows já preparado com Node 24.20.0/npm 11.19.0.

## Aplicação e gates no ambiente do usuário

O patch é incremental, exclusivamente sobre ca9aa60. Não executar sobre main nem sobre os primeiros candidatos. Preservar alterações locais; usar git apply --check antes de git apply. Não forçar aplicação, fazer rebase ou substituir histórico para contornar divergências.

No worktree com o patch aplicado e dentro de backend, com DATABASE_URL apontando para banco MySQL descartável exclusivo (sem seed demo), NODE_ENV=test e JWT_SECRET de teste:

```powershell
npx.cmd --no-install prisma migrate deploy
npm.cmd run build
node --test dist/modules/sync/sync.fe02b.rules.test.js dist/scripts/demo_seed.test.js
node --test --test-concurrency=1 dist/modules/sync/sync.fe02b.integration.test.js
node --test --test-concurrency=1 'dist/**/*.test.js'
```

Parar no primeiro erro e guardar o log/código de saída. Após aprovação dos gates, encaminhar o SHA/tree exatos e o delta ao Cyber para revisão somente desta correção. Se a importação produzir outro SHA, registrar o SHA local e comprovar a árvore equivalente. Se houver correções posteriores, fornecer o novo SHA e delta.

Não houve merge, push, mudança de Flutter, Prisma schema/migration ou novo seed executado neste trabalho. A correção está implementada e os testes locais passaram; a liberação Cyber continua pendente dos gates MySQL e da revisão do delta.
