# Changelog

Todas as mudanças notáveis deste projeto serão documentadas neste arquivo.

Formato baseado em [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) e
seguindo [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] – 2026-06-01
Primeira versão estável. 🎉

### Adicionado
- **Barra de progresso em tempo real** para liberar espaço e deletar, via **Server-Sent Events (SSE)**: o backend processa arquivo a arquivo e transmite o progresso ao vivo.
- Modal de progresso com barra animada, percentual, contagem (X de Y), nome do arquivo atual e **estimativa de tempo restante (ETA)**.
- **Botão Cancelar** durante a operação: ao fechar o stream, o servidor detecta a desconexão e interrompe o processamento.
- **Dashboard de discos**: `/api/suggestions` varre todos os volumes do sistema (`Get-PSDrive`) e retorna letra, rótulo, total, usado, livre e % de uso por disco.
- Detecção automática de OneDrive por disco (variáveis `OneDrive*` + pastas `OneDrive*` na raiz de cada drive), com destaque visual nos cards e atalhos diretos para cada caminho.

### Alterado
- **Endpoints `/api/free-space` e `/api/delete` agora respondem via SSE (GET)** em vez de JSON único (POST), permitindo progresso incremental.
- Liberação de espaço passa a usar a **API nativa Win32 (`SetFileAttributesW`)** para definir os atributos de nuvem `UNPINNED`/`PINNED` (equivalente a `attrib +U -P`), preservando os demais atributos e permitindo progresso por arquivo. O enum `[System.IO.FileAttributes]` do .NET rejeita esses bits, por isso a chamada nativa.
- Seção de sugestões transformada em mini-dashboard com cards e barras de uso (verde/amarelo/vermelho conforme ocupação); clicar no disco inicia a análise.
- Colunas numéricas da tabela (#, Arquivos, Lógico, Local, % Local) alinhadas à direita também no cabeçalho.

### Removido
- Funções não-streaming `Invoke-LiberarEspaco` e `Invoke-Deletar` (substituídas pelas versões com progresso `Invoke-LiberarEspacoStream` / `Invoke-DeletarStream`).

---

## [0.8.3] – 2026-05-31
### Adicionado
- **Interface HTML visual** (tema escuro Valebrum, responsiva, sem frameworks).
- **Backend PowerShell** com servidor HTTP local via `HttpListener` em `localhost:8080`.
- Endpoints REST: `GET /api/scan`, `GET /api/disk-free`, `GET /api/suggestions`, `POST /api/free-space`, `POST /api/delete`.
- Abertura automática do navegador ao iniciar o script.
- Resumo do disco: espaço livre, barra de uso do volume, total lógico vs. local e quanto é liberável.
- Tabela de subpastas com índice, nome, arquivos, tamanho lógico/local, % local e barras visuais de proporção.
- Ações por linha: **📂 Analisar** (drill-down), **☁️ Liberar** (somente-nuvem) e **🗑️ Deletar**.
- **Breadcrumb** de navegação entre níveis de pastas.
- Ordenação por qualquer coluna (clique no cabeçalho).
- Modal de confirmação para liberar/deletar e botão **Liberar tudo**.
- Auto-detecção de caminhos OneDrive comuns como sugestão inicial.
- Toasts de feedback (sucesso/aviso/erro) e re-scan automático após cada ação.
- Log de requisições no console com cores por status.

### Melhorado
- Lógica original de análise refatorada em funções reutilizáveis (`Get-AnaliseDePasta`, `Invoke-LiberarEspaco`, `Invoke-Deletar`).
- `Format-Tamanho` agora cobre B/KB/MB/GB.
- Cálculo de percentual local por subpasta e totais agregados.

### Migrado de
- Script CLI `tamanhosNasPastas0.83.ps1` (menu interativo no console) para projeto público com interface web.

---

## [0.8.0] – 2026-05-01 (legado, CLI)
### Adicionado
- Menu interativo no console: analisar caminho (N), deletar por índice (D), liberar espaço por índice (L), reanalisar por índice (A).
- Cálculo de tamanho lógico vs. local ignorando arquivos *Offline* (somente-nuvem).
- Liberação de espaço via `attrib +U -P` e exclusão de arquivos com confirmação `CONFIRMAR`.
- Exibição de espaço livre do volume e totais por análise.
