# ADR 001: Baseline Arquitetural e Estratégia Offline-First

* **Status:** Aceito
* **Data:** 2026-08-11
* **Autores:** Equipe de Arquitetura AssistAILab

---

## Contexto e Problema

O sistema AssistAILab precisa atender oficinas e assistências técnicas operando em múltiplas plataformas (Desktop Windows/macOS/Linux, Mobile Android/iOS e Web). O ambiente de trabalho exige resiliência a quedas de internet, rápida resposta na interface e operação contínua em múltiplos computadores no balcão e na bancada de atendimento.

---

## Decisões Aceitas

1. **Central API + Central MySQL como Autoridade Máxima**
   - A API central é o único ponto de acesso ao banco MySQL.
   - Nenhuma aplicação cliente lê ou escreve diretamente no MySQL.
   - A API Central é a autoridade responsável por autorização, validação de regras de negócio e integridade.

2. **SQLite para Persistência Operacional Local (Desktop & Mobile)**
   - O SQLite é adotado como banco de dados local para suporte offline-first.
   - Os dados no SQLite representam projeções operacionais locais e não a autoridade final.

3. **Separacao Estrita entre SQLite e Hive**
   - O Hive é restrito exclusivamente a preferências da UI, flags de sessão e configurações locais.
   - Dados de entidades de negócio (Clientes, Ordens de Serviço, Equipamentos) pertencem obrigatoriamente ao SQLite.

4. **Local Service no Desktop**
   - No Desktop, a comunicação do Flutter UI com o SQLite e a Sync Engine é intermediada por um **Local Service** independente.
   - O Local Service roda em background e expõe uma API REST local sobre `127.0.0.1:<porta>`.

5. **Sync Engine baseada em Outbox, UUIDs e Idempotência**
   - Todas as entidades sincronizáveis usam UUIDv4 gerado na origem (localmente).
   - Operações locais gravam eventos na tabela `outbox`.
   - O envio de retries utiliza `operation_id` para garantir idempotência na API Central.
   - A sincronização incremental consome a rota `GET /sync/changes?cursor=...`.

---

## Consequências

### Positivas
- **Resiliência Offline**: Atendimento e digitação de Ordens de Serviço continuam funcionando mesmo sem internet.
- **Segurança Robusta**: Nenhuma regra de autorização ou chave de banco central fica exposta nos clientes.
- **Desempenho da UI**: Leituras locais rápidas via SQLite no Desktop e Mobile.

### Negativas / Desafios
- **Complexidade de Sync Engine**: Necessidade de tratar sincronização de outbox, retries com backoff, cursores e eventual tratamento de conflitos.
- **Gerenciamento do Local Service**: Processo background no Desktop requer monitoramento de execução (health check) e gerenciamento de porta local.
