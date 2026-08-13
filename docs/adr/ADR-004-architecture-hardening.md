# ADR-004: Architecture & Security Hardening

- **Status:** Accepted
- **Data:** 2026-08-11
- **Autor:** AssistAiLab Engineering Team

---

## Contexto

A auditoria de arquitetura (`docs/audit/AUDIT.md`) identificou fragilidades em segurança crítica (fallbacks de segredo JWT, ausência de autorização central em rotas, possibilidade de privilege escalation no registro público), na ordenação do Sync Engine (cursor híbrido baseado em string/timestamp) e na gestão de resiliência local (Outbox simples sem timestamps de retry nem backoff).

## Decisões

1. **Segurança Crítica (P0)**:
   - **JWT Startup Check**: A API backend falha explicitamente no boot caso `JWT_SECRET` não esteja configurado no ambiente. Fallbacks hardcoded foram removidos.
   - **Prevencão de Privilege Escalation**: A rota pública de cadastro `/api/v1/auth/register` restringe a atribuição de `role` a `TECHNICIAN` ou `CUSTOMER`. O papel `ADMIN` é totalmente rejeitado em cadastros públicos.
   - **Autorização Central**: Todas as rotas protegidas foram equipadas com guards de autenticação JWT e validação de permissão por papel (`ADMIN`, `TECHNICIAN`, `CUSTOMER`).

2. **Integridade do Sync Engine & Idempotência (P1)**:
   - **Cursor Monotônico**: O cursor do log de alterações (`sync_change_logs`) foi unificado para utilizar o identificador sequencial `id` (`BigInt`) monotonicamente crescente, garantindo paginação determinística e eliminando perdas ou duplicidades de sincronização.
   - **Hash SHA-256 de Payload & Erro 409**: Toda operação idempotente registra o hash SHA-256 de seu payload. Se um mesmo `operation_id` for reenviado com payload distinto, o servidor rejeita com status `409 IDEMPOTENCY_KEY_REUSE`.
   - **State Machine de OS no Backend**: O backend é a autoridade máxima de validação das transições de status da Ordem de Serviço, rejeitando no servidor transições inválidas (ex.: `ENTREGUE` -> `DIAGNOSTICO`).

3. **Resiliência Local da Outbox & Retry (P1/P2)**:
   - **Tabela Outbox**: Adicionados os campos `last_attempt_at`, `next_retry_at` e `last_error`.
   - **Backoff Exponencial + Jitter**: Falhas temporárias de sincronização no cliente aplicam backoff exponencial (`2^attempt` segundos) com variação aleatória de jitter e limitador de taxa.

## Consequências

- A fundação do sistema tornou-se confiável, resiliente contra ataques de privilege escalation, pronta para operação offline-first e totalmente auditada por testes automatizados.
