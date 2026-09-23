# FE-02B — seed manual e isolamento das fixtures JWT

> Atualização: o seed padrão foi substituído pelo demo FE-02B. Ver `FE02B_DEMO_SEED.md`. As restrições ao seed legado descritas abaixo agora se aplicam a `prisma/seed.legacy.ts`; a correção de isolamento JWT permanece válida.

Data: 2026-09-16. Base desta correção: `263ba2e389fd5aa23ac97f756903f8de78b0add2`.

## Resultado da inspeção

`backend/prisma/seed.ts` é um dataset legado de demonstração manual. Cria/atualiza duas organizações, três clientes, seis usuários (dois administradores, um técnico e três clientes, incluindo onboarding pendente), memberships profissionais, quatro vínculos cliente/organização e quatro perfis CRM, sete equipamentos, doze OS, cinco peças globais, cinco itens de OS, três pagamentos legados, duas aquisições de equipamento, históricos, eventos CRM, um AccessGrant de onboarding e snapshots legados no ChangeLog.

O seed não cria a sequência de comandos financeiros, QuoteRevisions, decisões e bootstrap necessária para certificar FE-02B. Muitas OS de demonstração têm totais predefinidos sem coleção de itens correspondente. Não considerar esse dataset uma projeção monetária v2 validada.

Rerun não é uma operação somente de inserção: upserts substituem campos das fixtures (inclusive senhas das contas de demonstração), históricos das OS do seed são recriados e logs com cursor `seed:` são removidos/recriados. Usar somente em banco separado de demonstração, com a API parada. A checagem prévia não é um lock contra outra aplicação iniciada simultaneamente.

## Causa concreta do erro JWT

O seed atribui à organização B o ID `00000000-0000-0000-0000-000000000002`. O teste JWT usava exatamente esse ID e tentava excluir a organização no hook `before`, sem remover dependências criadas pelo seed. Isso explica a colisão possível e corresponde ao ponto de falha do log, embora o log não identifique qual tabela dependente bloqueou a exclusão.

As fixtures JWT agora usam UUIDs e e-mail exclusivos por execução. O hook inicial não exclui contas nem organizações preexistentes. O cleanup continua restrito aos IDs criados pelo próprio teste e tolera a ausência de app quando a preparação falha.

Não apagamos dados do seed, não desativamos FKs e não contornamos a falha com limpeza global.

## Ajustes do seed

- Preflight antes da primeira escrita bloqueia NODE_ENV=test e o banco assistailab_fe02b_test.
- Bloqueia também banco com a barreira __FE02B_PROJECTION_BARRIER__, pois suas escritas diretas não podem alterar projeções já ativadas. Falha ao consultar a barreira interrompe a execução.
- PART não gera novos eventos Sync. As peças permanecem apenas como dados legados de demonstração, sem conceder acesso pelo Sync.
- Snapshots legados de OS, itens e pagamentos serializam Decimal como texto exato, sem conversão para Number. Isso não transforma o seed em fixture v2.
- Corrigidas tipagens JSON Prisma que a compilação normal de src não verificava.
- Removida a orientação de apagar o SQLite; bootstrap v2 deve preservar a Outbox.

## Aplicação no Windows

Este patch é incremental sobre 263ba2e, não o pacote completo desde main. No worktree que contém aquele commit, confirme a identidade e preserve alterações locais:

```powershell
git rev-parse HEAD
git status --short
git apply --check "C:\caminho\FE02B_Seed_Fixture_Fix.patch"
git apply "C:\caminho\FE02B_Seed_Fixture_Fix.patch"
```

Se o check falhar, não force nem faça reset; peça ao Codex para comparar as alterações existentes. Faça commit desta correção separado da importação e da correção anterior.

## Validação e próximos comandos

Passaram localmente: build TypeScript do backend; compilação estrita do seed e seus helpers; cinco testes de preflight; git diff --check. Ambiente local Node 24.19.0 / npm 11.9.0, abaixo das versões requeridas pelo projeto. Não executamos seed, migrations ou testes MySQL aqui. A correção do JWT precisa de validação real no ambiente do usuário.

Os testes de preflight ficam em prisma, fora do glob padrão de testes de src. Para reproduzir a verificação adicional, dentro de backend:

```powershell
npx.cmd --no-install tsc --target ES2022 --module NodeNext --moduleResolution NodeNext --strict --esModuleInterop --skipLibCheck --outDir .seed-check prisma/seed.ts prisma/seed.preflight.ts prisma/seed.preflight.test.ts
node --test .seed-check/seed.preflight.test.js
```

Depois, na mesma sessão com DATABASE_URL já apontando para o banco exclusivo de testes, NODE_ENV=test e JWT_SECRET de teste:

```powershell
npm.cmd run build
node --test --test-concurrency=1 'dist/**/*.test.js' *> fe02b-test-results.log
$LASTEXITCODE
```

Não executar o seed antes da suíte. Os testes criam suas próprias fixtures. Esperar código de saída zero, sem falhas nem cancelamentos, e confirmar que os gates FE-02B realmente foram executados. O log anterior mostrava o teste antigo que permitia PART e não valida o candidato corrigido.

Escopo: seed, testes e documentação. Sem Flutter, schema Prisma, migrations, mudanças de autoridade financeira, merge ou deploy. Cyber Implementation Review continua pendente do gate completo.
