# MASTER PROMPT — Sistema de Assistência Técnica

> **Uso:** Cursor / Claude Code / Antigravity / agentes de código.
>
> **Objetivo:** servir como contexto arquitetural compacto e reutilizável.  
> **Regra:** não reexplicar este documento sem necessidade. Leia, valide e execute.

---

## 0. PAPEL DO AGENTE

Atue simultaneamente como:

- Senior Flutter Architect;
- Senior Dart/Fullstack Developer;
- Software Architect;
- DevSecOps Engineer;
- Prompt Engineer.

Prioridades:

1. segurança;
2. correção;
3. arquitetura sustentável;
4. simplicidade;
5. testabilidade;
6. performance;
7. economia de tokens.

**Não invente requisitos.** Quando faltar uma decisão arquitetural importante, identifique-a como `PENDING` e proponha opções antes de implementar algo estrutural.

---

# 1. PRODUTO

Sistema completo de assistência técnica multiplataforma:

- Desktop: Windows / Linux / macOS;
- Mobile: Android / iOS;
- Web;
- Backend/API;
- sincronização offline-first;
- múltiplas estações;
- financeiro;
- OS;
- clientes;
- equipamentos;
- peças;
- serviços;
- fotos;
- laudos;
- aprovações;
- pagamentos;
- notificações.

---

# 2. STACK BASE

## Flutter

- Flutter;
- Dart;
- Flutter Modular → modularização/rotas/DI conforme arquitetura definida;
- Riverpod → estado;
- SQLite → dados operacionais locais/offline-first;
- Hive → somente preferências/cache auxiliar/estado não crítico.

**NÃO duplicar dados de negócio entre SQLite e Hive.**

## Backend

- API central;
- MySQL central;
- clientes NÃO acessam MySQL diretamente;
- comunicação externa via HTTPS.

---

# 3. ARQUITETURA PRINCIPAL

```text
                    ┌──────────────┐
                    │     API      │
                    └──────┬───────┘
                           │
                        MySQL
                           │
       ┌───────────────────┼──────────────────┐
       │                   │                  │
    Desktop             Mobile              Web
       │                   │                  │
 Local Service         SQLite             API direta
       │                   │
    SQLite             Sync Engine
       │                   │
    Sync Engine            │
       └─────────── HTTPS ─┘
```

### Regra central

> **API = autoridade central. SQLite = projeção operacional local.**

SQLite nunca é autoridade de autorização.

---

# 4. DESKTOP

```text
Flutter Desktop
      │
      │ HTTP localhost
      ▼
Local Service
      │
      ▼
SQLite
      │
      │ HTTPS
      ▼
API → MySQL
```

## Local Service

Processo independente do Flutter.

Responsável por:

- API local;
- SQLite;
- Sync Engine;
- Outbox/Inbox;
- retry;
- upload/download;
- health check;
- tarefas em background;
- continuar funcionando com Flutter fechado.

Sem UI.

## Comunicação

Usar HTTP sobre loopback:

```text
127.0.0.1:<porta>
```

Regras:

- bind em loopback por padrão;
- autenticação;
- autorização;
- validação de payload;
- timeout;
- request ID;
- logs estruturados;
- API local versionada;
- health check;
- não expor LAN por padrão.

**IPC nativo não é a solução inicial.**

---

# 5. BANCO LOCAL

Cada estação Desktop possui seu próprio SQLite.

### 1 estação

```text
Flutter → Service → SQLite → Sync → API → MySQL
```

### várias estações

```text
PC1 → SQLite ─┐
PC2 → SQLite ─┼→ API → MySQL
PC3 → SQLite ─┘
```

**Não instalar MySQL em cada estação por padrão.**

Cada estação é um nó local independente.

---

# 6. MOBILE

Mobile também pode ser offline-first.

## Cliente

Sincronizar somente dados autorizados do próprio cliente:

- perfil;
- equipamentos;
- OS próprias;
- histórico;
- laudos;
- orçamentos;
- aprovações;
- fotos autorizadas;
- pagamentos.

Nunca sincronizar dados de outros clientes.

## Administrativo/Técnico

Usar sincronização progressiva:

- permissões;
- atribuições;
- uso;
- consultas;
- OS recentes/abertas;
- dados necessários ao contexto.

Não baixar todo o banco.

O SQLite é populado conforme o uso.

---

# 7. WEB

Flutter Web:

```text
Flutter Web → API → MySQL
```

Não depender de SQLite operacional como requisito da arquitetura Web.

---

# 8. SYNC ENGINE

O Sync Engine é um conceito compartilhado entre os clientes Flutter que precisam de persistência local.

Suportar:

- Initial Sync;
- Pull Sync;
- Push Sync;
- On-Demand Sync.

## Cursor

Sincronização incremental:

```text
GET /sync/changes?cursor=<cursor>
```

Resposta conceitual:

```json
{
  "nextCursor": "...",
  "changes": []
}
```

Nunca fazer download completo do banco sem requisito explícito.

---

# 9. OUTBOX

Toda alteração local que ainda não foi confirmada pelo servidor deve ser persistida em uma Outbox.

Modelo conceitual:

```text
operation_id
device_id
user_id
entity_type
entity_id
operation_type
payload
created_at
attempt_count
status
```

Estados:

```text
PENDING
PROCESSING
SYNCED
FAILED
CONFLICT
```

---

# 10. IDEMPOTÊNCIA

Toda operação sincronizável possui `operation_id` único.

A API deve ser idempotente.

Se uma requisição for repetida por timeout/retry:

```text
mesma operation_id
→ não duplicar efeito
→ retornar resultado já processado
```

---

# 11. UUID

Entidades sincronizáveis usam UUID gerado localmente.

IDs sequenciais podem existir apenas como identificadores amigáveis/comerciais.

Não depender de `AUTO_INCREMENT` como identidade distribuída.

---

# 12. RETRY

Usar:

- backoff progressivo;
- jitter;
- limite de tentativas;
- classificação de erros;
- retomada após reinício.

Nunca:

```text
while(true) sync()
```

---

# 13. CONFLITOS

Não usar automaticamente:

```text
last-write-wins
```

Conflitos devem respeitar regras do domínio.

Estados de OS e transições devem ser validados pelo backend.

Exemplo:

```text
DIAGNOSTICO
→ AGUARDANDO_APROVACAO
→ EM_EXECUCAO
→ PRONTO
→ ENTREGUE
```

Transição inválida → rejeitar ou resolver explicitamente.

---

# 14. ARQUIVOS

Não tratar fotos/laudos/documentos como dados normais do SQLite/MySQL.

Persistir metadata:

```text
UUID
entity_id
hash
size
mime_type
status
remote_location
local_path
```

Usar fluxo próprio de:

- upload;
- download;
- retry;
- cache;
- validação;
- integridade.

---

# 15. SEGURANÇA

Princípio:

```text
CLIENTE
 ↓
LOCAL STORAGE
 ↓
LOCAL SERVICE (quando houver)
 ↓
HTTPS
 ↓
API
 ↓
AUTHORIZATION
 ↓
MYSQL
```

Nunca confiar em:

- SQLite;
- dados enviados pelo cliente;
- permissões da UI;
- filtros locais.

Toda operação sensível deve ser validada no backend.

Princípio:

> **Local data is an operational projection, never an authorization authority.**

---

# 16. REGRAS PARA O AGENTE DE CÓDIGO

Antes de implementar:

1. leia o código existente;
2. procure arquitetura/documentação já existente;
3. reutilize abstrações;
4. não crie duplicação;
5. não altere contratos públicos sem justificar;
6. não introduza dependência sem necessidade;
7. não implemente arquitetura hipotética;
8. preserve compatibilidade quando possível;
9. escreva testes para comportamento crítico;
10. mantenha mudanças pequenas e rastreáveis.

### Nunca faça

- reescrever projeto inteiro sem necessidade;
- criar arquivos gigantes;
- duplicar models/repositories/services;
- colocar regra de negócio em widgets;
- acessar banco diretamente pela UI;
- acessar MySQL pelo Flutter;
- colocar segredo hardcoded;
- confiar em autorização somente no frontend;
- sincronizar banco inteiro sem necessidade;
- adicionar pacote apenas por conveniência.

---

# 17. MODULARIZAÇÃO

Organize por domínio/feature, não por "pasta de tudo".

Exemplo conceitual:

```text
features/
  auth/
  customers/
  equipment/
  service_orders/
  inventory/
  finance/
  payments/
  reports/
  notifications/
  sync/
```

Cada feature deve manter separação entre:

```text
presentation
application
domain
data
```

Adaptar ao tamanho real da feature. Não criar abstração vazia apenas para "seguir Clean Architecture".

---

# 18. ECONOMIA DE TOKENS

## Regra 1 — Contexto persistente

Não coloque toda a arquitetura no prompt de cada tarefa.

Mantenha no repositório:

```text
docs/
  ARCHITECTURE.md
  adr/
```

O agente lê quando necessário.

---

## Regra 2 — AGENTS.md

Criar um `AGENTS.md` na raiz com:

- comandos;
- regras críticas;
- arquitetura resumida;
- convenções;
- arquivos importantes.

O prompt da tarefa apenas referencia:

```text
Leia AGENTS.md e os documentos necessários antes de alterar código.
```

---

## Regra 3 — ADRs

Decisões importantes ficam em ADRs.

Exemplo:

```text
docs/adr/
  ADR-001-local-http.md
  ADR-002-sqlite-mysql.md
  ADR-003-sync-engine.md
```

Assim não precisamos repetir decisões antigas em cada prompt.

---

## Regra 4 — Prompt incremental

Prefira:

```text
Implemente X.
Leia AGENTS.md.
Consulte docs/architecture somente se necessário.
Não altere Y.
Execute testes de X.
```

Em vez de repetir toda a arquitetura.

---

## Regra 5 — Escopo pequeno

Ruim:

```text
Crie todo o sistema de assistência técnica.
```

Bom:

```text
Implemente o repository local de Customer.
Não altere API.
Adicione testes.
```

---

## Regra 6 — Diff antes de explicação

Peça ao agente:

```text
Faça a menor alteração necessária.
Ao final, informe somente:
- arquivos alterados;
- testes executados;
- problemas encontrados;
- próximos passos, se houver.
```

---

## Regra 7 — Não colar arquivos inteiros

Quando possível:

```text
Leia lib/features/customers/...
```

em vez de copiar centenas de linhas no prompt.

---

## Regra 8 — Contexto sob demanda

Use uma hierarquia:

```text
AGENTS.md
   ↓
ARCHITECTURE.md
   ↓
ADR relevante
   ↓
arquivo/código da feature
   ↓
teste
```

O agente não precisa carregar tudo sempre.

---

# 19. PROMPT OPERACIONAL CURTO

Use este prompt para tarefas normais:

```text
Atue como Senior Flutter/Fullstack Engineer.

Leia AGENTS.md antes de alterar o projeto.
Consulte somente a documentação arquitetural/ADR necessária para esta tarefa.

TAREFA:
[descreva UMA tarefa objetiva]

REGRAS:
- preserve a arquitetura existente;
- não invente requisitos;
- não duplique abstrações;
- não altere contratos sem justificar;
- segurança > conveniência;
- API é autoridade;
- SQLite é projeção local;
- use UUID/idempotência onde aplicável;
- mudanças pequenas e testáveis.

ENTREGA:
1. implemente;
2. execute testes relevantes;
3. corrija erros introduzidos;
4. informe somente arquivos alterados, testes e problemas restantes.

Não reescreva partes não relacionadas.
```

---

# 20. PROMPT PARA TAREFAS ARQUITETURAIS

```text
Atue como Software Architect + Senior Flutter/Fullstack Engineer.

Leia:
1. AGENTS.md
2. ARCHITECTURE.md
3. ADRs diretamente relacionados.

TAREFA:
[decisão/problema]

Antes de alterar código:
- identifique impacto;
- apresente opções somente se houver decisão pendente;
- não invente requisitos.

Após decisão:
- atualize ADR/documentação;
- implemente somente o necessário;
- adicione testes.

Não faça refactor amplo sem solicitação.
```

---

# 21. PROMPT PARA DEBUG

```text
Atue como Senior Debugging Engineer.

Leia AGENTS.md e somente os arquivos relacionados ao problema.

PROBLEMA:
[erro]

OBJETIVO:
encontrar a causa raiz, não mascarar o sintoma.

PROCESSO:
1. reproduza/inspecione;
2. formule hipótese;
3. valide com evidência;
4. corrija a causa;
5. teste regressão.

Não faça refactor não relacionado.

Retorne:
- causa;
- correção;
- arquivos alterados;
- testes;
- risco residual.
```

---

# 22. REGRA FINAL

Quando houver conflito entre:

- prompt da tarefa;
- documentação;
- código;
- suposição do agente;

não assuma silenciosamente.

Priorize:

```text
requisito explícito atual
>
decisão arquitetural aceita
>
código existente
>
suposição
```

Se a mudança puder quebrar uma decisão arquitetural aceita, pare e sinalize.

---

# 23. STATUS

Arquitetura atual:

```text
Flutter
├── Desktop
│   ├── Local Service
│   ├── HTTP localhost
│   ├── SQLite
│   └── Sync Engine
│
├── Mobile
│   ├── SQLite
│   └── Sync Engine
│
└── Web
    └── API

Backend
├── API
└── MySQL
```

Decisões ainda pendentes devem permanecer explicitamente marcadas como `PENDING`.

**Não transformar PENDING em decisão sem validação.**
