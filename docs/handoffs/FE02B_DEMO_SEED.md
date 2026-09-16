# FE-02B — seed fictício para demonstração e testes manuais

Data: 2026-09-16. Substitui a recomendação anterior de usar apenas o seed legado. O seed padrão agora é FE-02B; o anterior foi preservado como `prisma/seed.legacy.ts` e não é executado automaticamente.

## Conteúdo

- Duas assistências fictícias, dois administradores, um técnico e dois clientes.
- João possui OS nas duas assistências; Maria possui OS somente na A, permitindo conferir o isolamento de acesso.
- Nove equipamentos, nove OS e dezoito itens de serviço sem vínculo com PART global.
- Cenários: diagnóstico; aguardando aprovação; execução; pronto; entregue; aguardando reaprovação; revisão rejeitada; retomada do escopo aprovado; aprovação pendente na segunda assistência.
- Orçamento inicial: 15000 + 2 × 4590 = 24180 centavos (R$ 241,80). Revisões comerciais: 15000 + 2 × 5590 = 26180 centavos (R$ 261,80). O servidor calcula e persiste todos os totais.
- As OS pronta e entregue passam pelo comando mark-ready, que gera a conta a receber. Não são fabricados pagamentos nem baixas: esses cenários permitem demonstrar recebíveis em aberto.

As identidades e relações iniciais são criadas sob syncTransaction. OS e itens usam o Push v2 real, com autenticação e prova obtida por travessia completa do bootstrap. Publicação, aprovação/rejeição pelo cliente, revisão, retomada e conclusão usam os endpoints existentes por Fastify.inject (o mesmo pipeline da API, sem precisar abrir uma porta). Nunca gravamos QuoteRevision, hashes, snapshots financeiros, totais ou status comerciais diretamente no Prisma.

Ao final, o seed confere projeções staff/CUSTOMER, total calculado pelos itens, revisão decimal, ausência de campos internos no CUSTOMER, negação de acesso de outra assistência e bootstrap paginado de todas as contas. A prova usada pelo script não é exportada nem substitui o bootstrap do aplicativo.

## Reexecução

IDs e operationIds são determinísticos e separados das fixtures antigas. Reexecutar reproduz os mesmos comandos para obter replay idempotente. Não redefine senhas existentes, não limpa histórico, não altera hashes, não reinicia PROCESSING nem restaura edições feitas manualmente. Se um comando falhar, o script interrompe e mostra a resposta; corrigir a causa antes de repetir. O seed inteiro não é uma única transação: cenários anteriores podem ter concluído quando ocorrer uma falha, e a repetição usa os mesmos IDs para retomar.

O cenário mostrado ao final é o estado atual, que pode diferir do estado inicial depois dos testes manuais. Para reiniciar a demonstração do zero, use um ambiente demo descartável novo, não limpeza de entidades ou do SQLite por este script.

## Aplicar o pacote

O pacote contém duas alternativas; aplicar somente UMA:

- `FE02B_Demo_Seed_from_263ba2e.patch`: sobre o candidato corrigido 263ba2e, inclui também a correção anterior de isolamento JWT.
- `FE02B_Demo_Seed_after_Fixture_Fix.patch`: se o pacote anterior FE02B_Seed_Fixture_Fix já foi aplicado integralmente (árvore equivalente ao commit local 566ab7d).

No worktree FE-02B, examine `git status --short` e `git rev-parse HEAD`. Escolha o patch correspondente, execute `git apply --check CAMINHO_DO_PATCH` e só depois `git apply CAMINHO_DO_PATCH`. Em caso de divergência, peça ao Codex para integrar preservando alterações locais; não force/reset. O código continua local, sem push ou merge automático.

## Executar no MySQL existente — sem Docker

Crie um banco separado pelo Workbench ou cliente SQL que você já usa:

```sql
CREATE DATABASE IF NOT EXISTS assistailab_fe02b_demo CHARACTER SET utf8mb4;
```

Use uma conta local que tenha acesso a esse banco. Dentro de `backend` do worktree corrigido, no PowerShell:

```powershell
$env:DATABASE_URL = "mysql://USUARIO:SENHA@127.0.0.1:3306/assistailab_fe02b_demo"
$env:NODE_ENV = "development"
$env:JWT_SECRET = "assistailab-demo-local-secret-2026"
$env:SEED_DEMO_PASSWORD = "Demo@123456"

npx.cmd --no-install prisma migrate deploy
npm.cmd run prisma:generate
npm.cmd run seed
npm.cmd run dev
```

Substitua usuário/senha localmente; caracteres reservados da senha precisam de encoding de URL. Pare no primeiro erro. Os comandos aplicam somente migrations existentes. O comando seed faz build e usa Node, sem exigir o IPC de tsx; alternativamente, `npx prisma db seed` usa o novo wrapper `prisma/seed.ts`. Não execute os dois por necessidade: são entradas para o mesmo seed.

O seed aceita somente o banco `assistailab_fe02b_demo`, fora de NODE_ENV=test/production. A API iniciada no mesmo terminal usa esse banco. Configure o Frontend para essa instância de demonstração e faça login com uma das contas:

| Conta | Papel |
| --- | --- |
| admin.a@fe02b.demo.test | ADMIN da assistência A |
| admin.b@fe02b.demo.test | ADMIN da assistência B |
| tecnico@fe02b.demo.test | TECHNICIAN da assistência A |
| joao@fe02b.demo.test | CUSTOMER com OS nas assistências A e B |
| maria@fe02b.demo.test | CUSTOMER com OS na assistência A |

Senha inicial configurada: SEED_DEMO_PASSWORD (padrão Demo@123456). Alterar a variável em outra execução não troca a senha de contas existentes.

## Roteiro de validação manual

1. ADMIN A visualiza seus oito cenários; ADMIN B visualiza a OS da assistência B.
2. João visualiza suas OS nas duas assistências; Maria não visualiza as OS de João.
3. Abra aprovação pendente, aprove como cliente e confira a convergência na assistência.
4. Confira orçamento inicial e revisado, recusa e retomada: os ponteiros e o conjunto de itens devem acompanhar o escopo materializado, sem combinar itens de revisões diferentes.
5. Na OS pronta, confira o recebível gerado pelo comando comercial. Entrega não deve fabricar recebimento.
6. No Flutter com suporte FE-02B, execute o bootstrap completo e compare REST/Sync com a projeção SQLite aplicada atomicamente. Preserve a Outbox e não importe provas emitidas pelo seed.

Não há alteração Flutter neste pacote. O seed prepara dados coerentes no servidor; funcionalidades novas ainda dependem da implementação do contrato no cliente. PART, onboarding por QR, aquisição de estoque e baixas de pagamento não foram adicionados a este novo roteiro FE-02B.

## Testes e limites da evidência

O banco assistailab_fe02b_test continua dedicado à suíte automatizada, que cria suas próprias fixtures; não precisa do seed de demonstração. Os testes JWT isolados do pacote anterior estão incluídos na alternativa cumulativa.

Validação local: build passou; cinco testes do roteiro passaram (schemas monetários v2, replay estável, decisões vinculadas à revisão retornada, interrupção em erro e seleção do banco demo). Eles não substituem a execução MySQL. Ambiente local Node 24.19.0/npm 11.9.0; usar versões exigidas pelo projeto no Windows (Node 24.20.0/npm 11.19.0).

Não foi possível executar o seed contra MySQL neste ambiente. Portanto, dataset e suas verificações de integração ainda precisam ser executados no MySQL do usuário; Cyber Implementation Review e gate completo permanecem pendentes. Nenhuma migration/schema/Flutter/dependência foi alterada. O script não concede aprovação de implementação ou merge.
