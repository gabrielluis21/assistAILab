# AUDIT.md — Architecture Hardening

**Projeto:** AssistAiLab — Sistema de Assistência Técnica  
**Status:** 🔴 HARDENING REQUIRED  
**Objetivo:** corrigir riscos arquiteturais e de segurança identificados na auditoria antes da expansão das funcionalidades de negócio.

---

# 1. REGRA PRINCIPAL

> **NÃO adicionar novas funcionalidades de negócio durante esta fase.**

Não implementar agora:

- novas telas de negócio;
- WhatsApp;
- IA de peças;
- pagamentos reais;
- integração com maquininhas;
- notificações completas;
- relatórios avançados;
- novos módulos não relacionados ao hardening.

O objetivo desta fase é tornar a fundação atual confiável.

---

# 2. FONTE DA AUDITORIA

Esta auditoria foi baseada no estado atual do projeto compactado e na arquitetura já documentada no repositório.

As decisões arquiteturais existentes continuam válidas, exceto quando este documento marcar explicitamente uma correção necessária.

Não inventar requisitos.

Se uma correção exigir nova decisão arquitetural, marcar como:

```text
PENDING
```

e não assumir silenciosamente.

---

# 3. PRIORIDADES

Ordem obrigatória:

```text
P0 — Segurança crítica
P1 — Integridade do Sync Engine
P2 — Local Service
P3 — Testes e observabilidade
P4 — Documentação
```

---

# 4. P0 — SEGURANÇA CRÍTICA

## 4.1 JWT_SECRET

### Problema

Existe fallback de segredo JWT hardcoded.

### Correção

Remover fallback.

Se `JWT_SECRET` não existir:

```text
API não inicia.
```

Preferir falha explícita no startup.

### Critério

- [ ] nenhum segredo JWT hardcoded;
- [ ] aplicação falha sem configuração obrigatória;
- [ ] testes cobrindo configuração inválida.

---

## 4.2 Autenticação das rotas

### Problema

Existem endpoints administrativos que podem estar acessíveis sem autenticação.

### Correção

Revisar TODAS as rotas.

Classificar:

```text
PUBLIC
AUTHENTICATED
ADMIN
STAFF
CUSTOMER
SYSTEM
```

Nenhuma rota protegida pode depender apenas do frontend.

### Critério

- [ ] todas as rotas classificadas;
- [ ] middleware/guard aplicado;
- [ ] testes para acesso não autenticado;
- [ ] testes para acesso com perfil incorreto.

---

## 4.3 Registro de usuário e privilégio

### Problema

O registro não deve permitir que o cliente escolha livremente um papel privilegiado.

### Correção

Não aceitar:

```json
{
  "role": "ADMIN"
}
```

como autorização confiável do cliente.

Definir fluxo seguro para criação de usuários administrativos.

Se o fluxo ainda não estiver definido:

```text
PENDING
```

Não inventar fluxo de produção.

### Critério

- [ ] usuário público não consegue se tornar ADMIN;
- [ ] testes cobrindo privilege escalation.

---

## 4.4 Autorização por recurso

A API deve validar:

```text
quem é o usuário
+
qual seu papel
+
qual recurso está acessando
+
qual operação está tentando realizar
```

Exemplo:

```text
CUSTOMER A
→ pode consultar OS de CUSTOMER A

CUSTOMER A
→ NÃO pode consultar OS de CUSTOMER B
```

A autorização deve ocorrer no backend.

---

## 4.5 CORS

### Problema

Configuração atual permissiva para desenvolvimento.

### Correção

Separar configuração:

```text
development
production
```

Produção deve usar allowlist explícita.

Não quebrar desenvolvimento local.

---

# 5. P1 — IDEMPOTÊNCIA

## 5.1 Operation ID

Toda operação sincronizável deve possuir:

```text
operation_id
```

único.

---

## 5.2 Request Hash

O servidor deve registrar também uma representação/hash do payload recebido.

Objetivo:

```text
operation_id = X
payload A
```

repetido:

```text
→ retornar resultado existente
```

Mas:

```text
operation_id = X
payload B
```

deve gerar erro de reutilização da chave.

Sugestão:

```text
409 IDEMPOTENCY_KEY_REUSE
```

---

## 5.3 Concorrência

Evitar:

```text
find
↓
process
↓
insert
```

como operação não-atômica.

Projetar idempotência para resistir a duas requisições simultâneas.

Utilizar mecanismos transacionais/constraints do banco quando apropriado.

### Critério

Testar:

```text
request A + request B
mesmo operation_id
simultaneamente
```

Resultado esperado:

```text
efeito de negócio = 1
```

---

# 6. P1 — CURSOR DE SINCRONIZAÇÃO

## Problema

A implementação atual mistura:

```text
cursor baseado em timestamp/string
```

com:

```text
id incremental do banco
```

Isso deve ser simplificado.

## Decisão recomendada

Usar cursor monotônico baseado no identificador sequencial da change log.

Conceito:

```text
change_id
1001
1002
1003
1004
```

Cliente:

```text
cursor = 1002
```

Servidor:

```sql
WHERE change_id > 1002
ORDER BY change_id ASC
LIMIT N
```

Resposta:

```json
{
  "nextCursor": "1050",
  "changes": []
}
```

### Regras

- cursor monotônico;
- ordenação consistente;
- paginação determinística;
- não depender de relógio do cliente;
- não depender de timestamp como identidade do cursor.

### Critério

Testar:

- várias alterações no mesmo instante;
- paginação;
- reconexão;
- cursor antigo;
- cursor inválido;
- nenhum evento perdido;
- nenhum evento duplicado por erro de paginação.

---

# 7. P1 — OUTBOX

A Outbox deve ser persistente.

Estados:

```text
PENDING
PROCESSING
SYNCED
FAILED
CONFLICT
```

Adicionar, se ainda não existir:

```text
attempt_count
last_attempt_at
next_retry_at
last_error
```

## Fluxo

```text
PENDING
   ↓
PROCESSING
   ↓
SYNCED
```

Falha:

```text
PROCESSING
   ↓
FAILED
   ↓
next_retry_at
   ↓
PENDING
```

Conflito:

```text
PROCESSING
   ↓
CONFLICT
```

Não apagar automaticamente operações que falharam.

---

# 8. P1 — RETRY

Implementar retry com:

- backoff exponencial/progressivo;
- jitter;
- limite de tentativas;
- `next_retry_at`;
- classificação de erros.

Não executar retry agressivo.

Nunca:

```text
while(true) sync()
```

---

# 9. P1 — PULL SYNC

A implementação atual cobre apenas parte das entidades.

Não considerar o Sync Engine concluído enquanto somente `CUSTOMER` for sincronizado.

O protocolo deve ser preparado para entidades como:

```text
CUSTOMER
EQUIPMENT
SERVICE_ORDER
SERVICE_ORDER_ITEM
PART
PAYMENT
```

e outras que forem oficialmente adicionadas ao domínio.

### Importante

Não implementar todas as entidades apenas para "completar".

Primeiro criar mecanismo genérico/reutilizável.

Depois adicionar entidades conforme domínio.

---

# 10. P1 — ARQUIVOS

## Problema

A implementação/documentação utiliza MD5.

## Correção

Usar SHA-256 para integridade de arquivos.

Renomear conceitualmente:

```text
hash_md5
```

para:

```text
hash_sha256
```

quando houver alteração de schema.

Metadata esperada:

```text
id
entity_id
hash_sha256
size
mime_type
status
remote_location
local_path
```

Não armazenar arquivo grande diretamente como payload de sincronização normal.

---

# 11. P1 — ESTADO DA OS

A máquina de estados deve existir em dois níveis:

### Flutter

Para UX e validação antecipada.

### Backend

Como autoridade real.

Nunca confiar em:

```text
status enviado pelo cliente
```

sem validação.

Exemplo:

```text
DIAGNOSTICO
→ AGUARDANDO_APROVACAO
→ EM_EXECUCAO
→ PRONTO
→ ENTREGUE
```

Transições inválidas devem ser rejeitadas pelo backend.

Não usar somente a implementação Flutter como regra de segurança.

---

# 12. P2 — LOCAL SERVICE

## Problema atual

O `LocalServiceRunner` está iniciado pelo processo Flutter.

Isso não corresponde ao conceito final de:

```text
processo independente
```

## Estado desejado

```text
Flutter Desktop
      │
      │ HTTP localhost
      ▼
Local Service
      │
      ├── SQLite
      ├── Sync Engine
      ├── Outbox Worker
      ├── Pull Worker
      ├── Upload Worker
      └── Health Monitor
```

O Local Service deve continuar funcionando quando a interface Flutter for fechada.

---

# 13. LOCAL SERVICE — PENDING

Ainda é necessário definir formalmente o mecanismo de instalação/execução:

```text
Windows → Windows Service
Linux   → systemd
macOS   → launchd
```

Não assumir detalhes de instalação antes de uma ADR específica.

Até lá:

```text
PENDING
```

---

# 14. LOCAL SERVICE — CONFIGURAÇÃO

Não deixar URL de produção hardcoded.

Separar:

```text
development
staging
production
```

Exemplo conceitual:

```text
development:
http://127.0.0.1:3000

production:
https://api.example.com
```

A URL deve vir de configuração apropriada.

---

# 15. P2 — ARMAZENAMENTO DE CREDENCIAIS

Não utilizar Hive puro para armazenar credenciais sensíveis.

Hive pode continuar para:

- preferências;
- cache auxiliar;
- estado não crítico.

Tokens/segredos devem usar armazenamento seguro da plataforma ou abstração equivalente.

Exemplos de mecanismos a avaliar:

```text
Windows Credential Manager
macOS Keychain
Android Keystore
iOS Keychain
Linux Secret Service
```

Se a biblioteca definitiva ainda não estiver escolhida:

```text
PENDING
```

Não inventar pacote sem avaliar compatibilidade multiplataforma.

---

# 16. P3 — TESTES

Criar testes antes de considerar o hardening concluído.

## Backend

Cobrir no mínimo:

- auth;
- authorization;
- privilege escalation;
- idempotência;
- concorrência de idempotência;
- cursor;
- paginação;
- Outbox;
- conflitos;
- transições da OS.

## Flutter

Cobrir no mínimo:

- repositories;
- Outbox;
- Sync Engine;
- transições locais;
- tratamento offline;
- persistência;
- recuperação após reinício.

## Integração

Validar:

```text
SQLite
→ Outbox
→ API
→ MySQL
→ Change Log
→ Pull
→ SQLite
```

---

# 17. P3 — OBSERVABILIDADE

Manter logs estruturados.

Operações de sincronização devem permitir rastrear:

```text
device_id
user_id
operation_id
entity_type
entity_id
attempt
status
error
timestamp
```

Não registrar:

- senha;
- JWT;
- token;
- dados sensíveis desnecessários.

---

# 18. P4 — DOCUMENTAÇÃO

Atualizar documentação somente quando houver mudança real.

Não criar ADR para cada pequeno detalhe de implementação.

Criar ADR quando houver:

- decisão arquitetural;
- mudança de tecnologia;
- mudança de protocolo;
- trade-off relevante;
- decisão difícil de reverter.

---

# 19. CHECKLIST DE CONCLUSÃO

## P0

- [ ] JWT sem fallback inseguro
- [ ] todas as rotas classificadas
- [ ] autenticação aplicada
- [ ] autorização aplicada
- [ ] privilege escalation bloqueado
- [ ] CORS adequado

## P1

- [ ] idempotência robusta
- [ ] request hash
- [ ] proteção contra concorrência
- [ ] cursor monotônico
- [ ] Outbox persistente
- [ ] estados corretos
- [ ] retry com backoff
- [ ] `next_retry_at`
- [ ] Pull Sync consistente
- [ ] SHA-256 para arquivos
- [ ] state machine validada no backend

## P2

- [ ] Local Service independente
- [ ] workers em background
- [ ] configuração por ambiente
- [ ] armazenamento seguro de credenciais

## P3

- [ ] testes unitários
- [ ] testes de integração
- [ ] testes de sincronização
- [ ] logs estruturados
- [ ] testes de regressão

## P4

- [ ] ADRs atualizados
- [ ] ARCHITECTURE.md atualizado
- [ ] AGENTS.md atualizado somente se necessário

---

# 20. REGRAS PARA O AGENTE

Ao trabalhar neste AUDIT:

### FAÇA

- leia `AGENTS.md`;
- leia `ARCHITECTURE.md`;
- leia somente ADRs relevantes;
- faça pequenas mudanças;
- escreva testes;
- execute os testes;
- corrija regressões;
- mantenha compatibilidade quando possível;
- documente decisões reais.

### NÃO FAÇA

- adicionar funcionalidades de negócio;
- reescrever o projeto;
- refatorar arquivos não relacionados;
- trocar stack sem ADR;
- adicionar dependências sem necessidade;
- inventar regras de negócio;
- considerar SQLite como autoridade;
- confiar em autorização frontend;
- implementar segurança apenas por obscuridade;
- marcar PENDING como resolvido sem decisão.

---

# 21. FORMATO DE ENTREGA DO AGENTE

Ao finalizar cada etapa, responder somente:

```text
STATUS: PASS | PARTIAL | BLOCKED

ALTERAÇÕES:
- arquivo — alteração

TESTES:
- comando — resultado

RISCOS:
- risco restante, se houver

PENDING:
- decisão necessária, se houver
```

Não produzir explicações longas.

---

# 22. DEFINIÇÃO DE "HARDENING CONCLUÍDO"

O hardening somente estará concluído quando:

```text
Segurança crítica
        +
Idempotência
        +
Cursor
        +
Outbox
        +
Retry
        +
Sync
        +
State Machine
        +
Local Service
        +
Testes
```

estiverem validados.

Depois disso, criar nova fase:

```text
FEATURE DEVELOPMENT
```

---

# 23. PRÓXIMA FASE

Somente após este documento estar satisfatoriamente concluído:

```text
Clientes
→ Equipamentos
→ OS
→ Diagnóstico
→ Orçamento
→ Aprovação
→ Peças
→ Serviços
→ Laudos
→ Fotos
→ Financeiro
→ Pagamentos
→ Notificações
→ WhatsApp
→ IA
```

A ordem acima é uma referência de domínio, não uma autorização para implementar tudo automaticamente.

---

# FINAL

> **Estabilizar a fundação antes de escalar funcionalidades.**

O objetivo desta fase não é fazer o sistema parecer pronto.

O objetivo é garantir que a arquitetura não precise ser reconstruída quando o sistema crescer.
