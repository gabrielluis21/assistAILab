# ADR 002: Escolha da Stack do Backend Central (API & Sync Engine)

* **Status:** Aceito
* **Data:** 2026-08-11
* **Autores:** Equipe de Arquitetura AssistAILab

---

## Contexto e Problema

O backend do AssistAILab precisa atuar como a autoridade central de dados, segurança e autorização para todas as instâncias (Desktop, Mobile e Web). Ele deve processar operações síncronas (REST/HTTPS) e assíncronas (Sync Engine, processamento de Outbox, controle de Idempotência e sincronização incremental baseada em cursores).

---

## Decisões Aceitas

1. **Stack do Backend: Node.js + TypeScript + Fastify**
   - **Node.js com TypeScript**: Oferece tipagem estática rigorosa, performance assíncrona para I/O e rico ecossistema de bibliotecas.
   - **Fastify**: Escolhido por seu alto desempenho de throughput HTTP, validação integrada via JSON Schema/Zod e baixo overhead de memória.

2. **ORM & Banco de Dados: Prisma ORM + MySQL Central**
   - **MySQL**: Banco relacional central autoritativo.
   - **Prisma ORM**: Proporciona migrações declarativas com versionamento de schema, tipagem gerada automaticamente em TypeScript e proteção robusta contra SQL Injection.

3. **Mecanismo de Idempotência e Sync Engine**
   - Tabela `operation_idempotency` armazena `operation_id` (UUIDv4) enviada pelo cliente.
   - Tabela `sync_change_logs` armazena o histórico de alterações com um cursor sequencial/timestamp para permitir buscas do tipo `GET /sync/changes?cursor=<cursor>`.

---

## Consequências

### Positivas
- Validação de entrada rápida e fortemente tipada.
- Migrações de banco rastreáveis no repositório.
- Alta performance em rotas de sincronização de lote (Outbox).

### Negativas / Desafios
- Necessidade de manter schemas Prisma sincronizados com o modelo conceitual de domínio.
