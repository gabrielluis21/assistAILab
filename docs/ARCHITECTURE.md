# Arquitetura do Sistema — AssistAILab

> **Visão Geral:** O AssistAILab é uma plataforma completa para gestão de assistência técnica (clientes, equipamentos, ordens de serviço, peças, laudos, pagamentos e notificações) operando em modelo multiplataforma com sincronização **offline-first**.

---

## 1. TOPOLOGIA DO SISTEMA

```text
                    ┌──────────────────────────┐
                    │       API Central        │
                    └────────────┬─────────────┘
                                 │
                            MySQL Central
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                        │
     Desktop                   Mobile                    Web
        │                        │                        │
  Local Service                SQLite                 API direta
        │                        │                        │
     SQLite                 Sync Engine                   │
        │                        │                        │
   Sync Engine                   │                        │
        └──────────── HTTPS ─────┴───────────── HTTPS ────┘
```

---

## 2. COMPONENTES E PLATAFORMAS

### 2.1 Desktop (Windows / macOS / Linux)

```text
Flutter Desktop UI
      │
      │ HTTP (127.0.0.1:<porta>)
      ▼
Local Service (Processo Background)
      │
      ├── SQLite (Dados Operacionais Locais)
      ├── Outbox / Inbox Table
      └── Sync Engine Process (Background HTTPS Sync)
            │
            ▼ HTTPS
       API Central → MySQL Central
```

* **Local Service**: Serviço independente sem UI que gerencia a persistência local (SQLite), sincronização background e fila Outbox. Permite que retries e uploads continuem rodando mesmo se a janela do aplicativo Flutter for fechada.
* **Comunicação**: O Flutter Desktop conversa com o Local Service via API REST local sobre `127.0.0.1` (loopback) com autenticação via token local, validação de payload e request ID.

---

### 2.2 Mobile (Android / iOS)

```text
Flutter Mobile UI
      │
      ├── SQLite (Dados autorizados / progressivos)
      └── Sync Engine (Execução interna / background tasks)
            │
            ▼ HTTPS
       API Central → MySQL Central
```

* **Cliente Final**: Sincroniza **somente** dados referentes ao próprio cliente (perfil, suas OSs, equipamentos e laudos). Nunca baixa dados de outros clientes.
* **Técnico / Administrativo**: Sincronização progressiva on-demand. Baixa OSs atribuídas, catálogo de peças e dados necessários ao contexto ativo.

---

### 2.3 Web (Flutter Web)

```text
Flutter Web UI ────────── HTTPS ──────────► API Central ──► MySQL Central
```

* Conexão direta via HTTPS com a API central.
* Não depende de SQLite operacional local para seu funcionamento.

---

## 3. PERSISTÊNCIA LOCAL DE DADOS

| Tecnologia | Finalidade | Restrições |
| :--- | :--- | :--- |
| **SQLite** | Projeção operacional local, dados de negócio offline (OSs, Clientes, Peças). | Não é autoridade de segurança nem autorização. |
| **Hive** | Preferências do usuário, temas, tokens de sessão local, estado de UI não crítico. | **PROIBIDO** duplicar dados de negócio salvos no SQLite. |

---

## 4. SYNC ENGINE & PROTOCOLO DE SINCRONIZAÇÃO

### 4.1 Outbox Pattern
Toda mutation local (criação/edição/exclusão de OS, cliente, laudo) que ocorre offline ou localmente é primeiro gravada na tabela `outbox` no SQLite com os seguintes atributos conceituais:

```text
- operation_id: UUIDv4 único da operação
- device_id: UUID do dispositivo/estação
- user_id: ID do usuário autenticado
- entity_type: ex: "SERVICE_ORDER", "CUSTOMER"
- entity_id: UUID da entidade afetada
- operation_type: CREATE | UPDATE | DELETE
- payload: JSON com os dados da alteração
- created_at: Timestamp UTC de criação local
- attempt_count: Número de tentativas de envio
- status: PENDING | PROCESSING | SYNCED | FAILED | CONFLICT
```

### 4.2 Idempotência
A API Central obriga o uso de `operation_id` em toda requisição de modificação enviada pelo Sync Engine. Se a requisição for reenviada devido a timeout ou perda de conexão, a API Central identifica o `operation_id` repetido e retorna a resposta anterior sem reprocessar ou duplicar efeitos colaterais.

### 4.3 Sincronização Incremental (Pull Sync)
O Sync Engine realiza pull incremental solicitando alterações a partir de um ponteiro/cursor:
`GET /sync/changes?cursor=<ultimo_cursor_recebido>`

A API responde com as alterações e o `nextCursor`.

### 4.4 Resolução de Conflitos
* Não utilizar estratégia cega de *last-write-wins*.
* Regras de domínio e máquina de estados da Ordem de Serviço (ex: `DIAGNOSTICO` → `AGUARDANDO_APROVACAO` → `EM_EXECUCAO` → `PRONTO` → `ENTREGUE`) são validadas e mantidas pela API Central. Transições inválidas acionam estado de `CONFLICT` na Outbox para resolução apropriada.

---

## 5. GERENCIAMENTO DE MÍDIAS E ARQUIVOS (FOTOS E LAUDOS)

Fotos de equipamentos, laudos técnicos e comprovantes **não são gravados como Blobs** no SQLite/MySQL.

1. **Metadados locais**: Gravados no banco com `file_uuid`, `entity_id`, `hash_md5`, `size_bytes`, `mime_type`, `local_path` e `status_upload` (`PENDING_UPLOAD`, `UPLOADED`).
2. **Upload/Download Background**: Gerenciado por worker dedicado com retry progressivo e retomada de upload interrompido.

---

## 6. ARQUITETURA DE SEGURANÇA

* **API Central como Autoridade**: Toda validação de permissões, autorização de acesso a dados e regras de negócio é feita estritamente no backend (API Central).
* **HTTPS Obrigatório**: Comunicação externa entre estações/dispositivos móveis e a API Central sempre via HTTPS com TLS 1.3/1.2.
* **Segurança do Local Service**: Bind em `127.0.0.1` por padrão para evitar acesso via rede local não autorizada.
