# AGENTS.md — Diretrizes para Agentes de Código no AssistAILab

> Este documento resume as regras arquiteturais, convenções de código e princípios de desenvolvimento do projeto **AssistAILab**. Leia este arquivo antes de realizar qualquer alteração estrutural no projeto.

---

## 1. PAPEL DO AGENTE
Atue simultaneamente como:
- **Senior Flutter Architect**
- **Senior Dart / Fullstack Developer**
- **Software Architect**
- **DevSecOps Engineer**
- **Prompt Engineer**

### Prioridades Principais
1. Segurança
2. Correção
3. Arquitetura sustentável
4. Simplicidade
5. Testabilidade
6. Performance
7. Economia de tokens

*Não invente requisitos.* Quando faltar uma decisão arquitetural importante, identifique-a como `PENDING` e proponha opções antes de implementar.

---

## 2. REGRAS DE OURO DA ARQUITETURA

1. **API = Autoridade Central | SQLite = Projeção Operacional Local**
   - Os dados no SQLite local são projeções operacionais offline-first. O banco central (MySQL via API) é a autoridade máxima de autorização e integridade.
   - NUNCA acesse o MySQL diretamente a partir dos clientes (Flutter Desktop, Mobile ou Web). Toda comunicação externa é via HTTPS.

2. **Divisão de Persistência Local (Flutter/Desktop/Mobile)**
   - **SQLite**: Persistência de dados operacionais e de negócio offline-first.
   - **Hive**: EXCLUSIVAMENTE para preferências do usuário, flags de sessão ou cache auxiliar leve.
   - **Regra**: NÃO duplicar dados de negócio entre SQLite e Hive.

3. **Desktop & Local Service**
   - O Desktop executa um **Local Service** (processo independente em background, sem UI) que gerencia o SQLite local, a Outbox/Inbox e a Sync Engine.
   - Comunicação entre Flutter Desktop e Local Service via HTTP em Loopback (`127.0.0.1:<porta>`).
   - O Local Service deve continuar rodando em background mesmo se a interface Flutter for fechada.

4. **Mobile & Progressive Sync**
   - **Clientes**: Sincronizam apenas dados autorizados do próprio cliente (OSs, equipamentos, laudos, pagamentos). Nunca sincronizam dados de outros clientes.
   - **Técnicos/Admins**: Sincronização progressiva on-demand conforme permissões e contexto.

5. **Flutter Web**
   - Flutter Web conecta-se diretamente à API central via HTTPS (`Flutter Web → API → MySQL`). Não depende de SQLite local.

6. **Sync Engine, Outbox & Idempotência**
   - **UUID**: Entidades sincronizáveis utilizam UUID gerado localmente. IDs sequenciais são apenas para exibição comercial amigável.
   - **Outbox**: Alterações locais pendentes de confirmação do servidor devem ser salvas na tabela `outbox` (`operation_id`, `entity_type`, `payload`, `status`, etc.).
   - **Idempotência**: Toda requisição sincronizável envia `operation_id` único para evitar reprocessamento/duplicação em retries.
   - **Cursor**: Sincronização incremental usando cursores (`GET /sync/changes?cursor=<cursor>`).

7. **Arquivos, Mídias e Laudos**
   - NUNCA armazenar arquivos binários (fotos/laudos/PDFs) como blobs no SQLite/MySQL.
   - Armazenar apenas metadados (UUID, entity_id, hash, mime_type, remote_location, local_path) e gerenciar via pipeline dedicado de upload/download/cache.

---

## 3. ESTRUTURA DE MODULARIZAÇÃO

O código do frontend (Flutter) e backend deve ser organizado por **domínios/features**:

```text
lib/
├── core/                  # Abstrações base, utilitários, temas, rede, banco local
│   ├── network/
│   ├── database/
│   └── sync/
└── features/              # Funcionalidades isoladas por contexto de negócio
    ├── auth/
    ├── customers/
    ├── equipment/
    ├── service_orders/
    ├── inventory/
    ├── finance/
    ├── payments/
    ├── reports/
    └── notifications/
```

Cada feature deve seguir a separação:
- `presentation`: Widgets, telas, controllers/providers (Riverpod).
- `application`: Use cases, orquestração da regra de aplicação.
- `domain`: Entities, Value Objects, contratos de repositories.
- `data`: Repositories (implementações), Datasources (SQLite, Remote API), DTOs, Mappers.

---

## 4. O QUE NUNCA FAZER

- ❌ Reescrever o projeto ou criar abstrações gigantescas sem necessidade.
- ❌ Colocar regra de negócio em widgets da UI.
- ❌ Acessar o banco de dados diretamente a partir da UI.
- ❌ Armazenar chaves/segredos hardcoded no código.
- ❌ Confiar na autorização apenas no frontend.
- ❌ Sincronizar o banco de dados inteiro em clientes mobile.
- ❌ Usar `last-write-wins` sem validar regras de transição de estado de negócio (ex.: transições de status de Ordens de Serviço).

---

## 5. HIERARQUIA DE CONTEXTO E DECISÕES

Ao realizar tarefas no AssistAILab, siga esta prioridade para esclarecer dúvidas:
1. Requisito explícito atual da tarefa
2. `AGENTS.md` (este documento)
3. `docs/ARCHITECTURE.md`
4. ADRs relevantes (`docs/adr/*.md`)
5. Código fonte existente
