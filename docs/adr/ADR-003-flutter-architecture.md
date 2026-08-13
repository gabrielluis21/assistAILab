# ADR 003: Arquitetura do Cliente Flutter e Local Service

* **Status:** Aceito
* **Data:** 2026-08-11
* **Autores:** Equipe de Arquitetura AssistAILab

---

## Contexto e Problema

O aplicativo frontend precisa rodar em Desktop (Windows, macOS, Linux), Mobile (Android, iOS) e Web de forma unificada. Ele precisa suportar persistência de dados no SQLite local (offline-first), gerenciamento de estado previsível, modularização escalável por domínios e a execução de um **Local Service** independente em background no Desktop.

---

## Decisões Aceitas

1. **Arquitetura Modular: Flutter Modular**
   - Injeção de dependências e roteamento declarativo organizado por domínios (`features/customers`, `features/service_orders`, `features/sync`, etc.).

2. **Gerenciamento de Estado: Riverpod (StateNotifierProvider / NotifierProvider)**
   - Separação clara de estado da interface com suporte reativo e testabilidade sem dependência da árvore de widgets.

3. **Estratégia de Persistência Local (SQLite vs Hive)**
   - **SQLite (`sqflite` / `sqflite_common_ffi`)**: Banco de dados relacional offline para Ordens de Serviço, Clientes, Equipamentos, Peças e a tabela `outbox`.
   - **Hive**: Uso estritamente reservado para preferências de usuário (tema escuro/claro, preferências de janela, flags locais).

4. **Desktop Local Service (`127.0.0.1:<porta>`)**
   - No Desktop, o `local_service_runner.dart` inicializa um servidor HTTP local em loopback (`127.0.0.1:8080`) que executa tarefas da Outbox, sincronização background e gerenciamento do SQLite de forma desacoplada da UI.

---

## Consequências

### Positivas
- Código limpo e modular por domínios (`presentation`, `application`, `domain`, `data`).
- Interface responsiva com execução background não bloqueante no Desktop.
- Rigor na garantia de não duplicação de dados entre SQLite e Hive.

### Negativas / Desafios
- Manutenção do fallback entre suporte a `sqflite` mobile e `sqflite_common_ffi` no Desktop.
