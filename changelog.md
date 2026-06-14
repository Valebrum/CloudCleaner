# Changelog

Todas as mudanças notáveis deste projeto serão documentadas neste arquivo.

Formato baseado em [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) e
seguindo [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.1] – 2026-06-13
Suporte a **Google Drive for Desktop** (detecção) + correção de um bug latente de espaço. (#17)

### Pesquisa (Mirror vs Stream)
- O Google Drive for Desktop **não usa a Cloud Files API do Windows** como o OneDrive. Foram mapeados dois modos:
  - **Stream** — monta um **volume virtual FAT32** (rótulo `Google Drive`, padrão `G:`) onde os arquivos aparecem com o **tamanho lógico** e atributo `Normal`. O FAT32 **não suporta** os bits `Offline`/`Pinned`/`Unpinned`, então `attrib +U` / `SetFileAttributesW(UNPINNED)` **não liberam nada**. O footprint local real é o `content_cache` em `%LOCALAPPDATA%\Google\DriveFS\<conta>\content_cache`.
  - **Mirror** — sincroniza uma **pasta local real (NTFS)**; todo arquivo é cópia local, recuperável só deletando ou trocando a pasta para Stream.

### Adicionado
- **Detecção de Google Drive** por assinatura de volume (`VolumeName = "Google Drive"`, independente do idioma — funciona com `Meu Drive`/`My Drive`) e por varredura de pastas (Mirror). Novas funções: `Test-IsGoogleDriveStreamVolume`, `Get-GoogleDriveStreamVolumes`, `Get-GoogleDriveCacheInfo`, `Get-CaminhosGoogleDrive`, `Resolve-CloudInfo`, `Get-PathCloudInfo`.
- `/api/suggestions` agora retorna um bloco `googleDrive` (instalado, **tamanho do content_cache**, contas, caminhos) e flags `hasGoogleDrive`/`googleDrivePaths` por disco.
- `/api/scan` retorna um bloco `cloud` (`provider`, `mode`, `freeable`, `note`) classificando o caminho analisado.
- **Frontend**: badge e atalhos de Google Drive nos cards (com selo `stream`/`espelho`), exibição do cache local, e um **aviso explicativo** quando a pasta é Google Drive.
- Switch **`-NoBrowser`** para subir o servidor sem abrir o navegador (execução headless/CI).
- **Testes** sem dependência de Pester em `tests/Run-Tests.ps1` (21 asserts sobre as funções puras).

### Corrigido
- **Bug latente de espaço**: apontar a "Liberar espaço" para uma pasta do Google Drive **Stream** era um no-op que **super-reportava** bytes liberados (no FAT32 todos os arquivos contam como locais). Agora `/api/free-space` **recusa** caminhos do Google Drive com mensagem clara, e a UI **desativa** os botões de liberar e mostra `Liberável por atributo: N/D`.
- Cards de disco com **um único** caminho de nuvem deixavam de renderizar o atalho (PowerShell `ConvertTo-Json` desempacota arrays de 1 elemento); normalizado no frontend com `asArray()`.

### Notas
- A *limpeza* do cache do Stream (deletar `content_cache`) **não** é automatizada nesta versão por segurança (o DriveFS precisa estar parado). A ferramenta detecta e orienta; clearing guardado fica como follow-up.

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
