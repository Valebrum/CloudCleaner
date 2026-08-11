# Changelog

Todas as mudanças notáveis deste projeto serão documentadas neste arquivo.

Formato baseado em [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) e
seguindo [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.3.1] – 2026-08-11
Correção: o instalador funcionava, mas o atalho instalado "não fazia nada" ao ser
executado numa máquina Windows real (o `.exe` do 1.3.0 tinha sido compilado via Wine,
nunca testado em Windows de verdade). Task TaskHub #2760 (rework).

### Corrigido
- **Erro fatal agora é VISÍVEL.** O launcher roda 100% oculto (sem janela de PowerShell)
  — antes, qualquer falha na inicialização (porta 8080 ocupada, erro ao registrar o tipo
  nativo Win32, exceção não prevista) só escrevia `Write-Host` numa janela que ninguém
  via: o processo simplesmente morria em silêncio, indistinguível de "nada aconteceu".
  Agora: (a) `Start-Transcript` grava toda a execução em `CloudCleaner.log` ao lado do
  programa; (b) qualquer erro fatal grava em `CloudCleaner-error.log` E mostra uma caixa
  de mensagem (`System.Windows.Forms.MessageBox`) explicando o problema; (c) o local do
  log cai automaticamente para `%LOCALAPPDATA%\CloudCleaner` (ou `%TEMP%\CloudCleaner`)
  se o diretório de instalação não for gravável pelo usuário atual.
- **`[Console]::OutputEncoding` deixou de poder derrubar o script inteiro.** Era a
  primeira instrução executada; lançava `IOException` ("The handle is invalid") em
  processos sem console de verdade anexado — cenário plausível para o launcher via
  `wscript.exe` + `powershell.exe -WindowStyle Hidden`. Agora envolvida em try/catch
  (é só cosmético — não pode ser fatal).
- **`Add-Type` do tipo nativo `Win32.NativeFs`** também passou a ficar protegido por
  try/catch (registrado no log de erro em vez de matar o processo inteiro).
- **Instalador (`CloudCleaner.iss`): defesa contra "Mark of the Web".** Desde o Inno
  Setup 6.1, se o `setup.exe` (baixado do GitHub, então marcado como "da internet")
  carrega essa marca, os arquivos que ele extrai herdam a mesma marca — silenciosamente.
  Um passo novo (`Unblock-File`, oculto, executado durante a instalação) remove a marca
  dos arquivos recém-copiados antes de oferecer "Abrir agora".
- **Launcher (`CloudCleaner.vbs`) ganhou seu próprio log de falha.** Se o próprio passo
  de disparar o PowerShell falhar (objeto COM indisponível, `WScript.Shell.Run`
  rejeitando o comando), agora grava `CloudCleaner-launch-error.log` ao lado do launcher
  em vez de falhar 100% em silêncio, sem nem chegar a rodar o `.ps1` (e portanto sem
  nenhum outro log que registrasse o problema).

---

## [1.3.0] – 2026-08-08
Instalador Windows + o programa aprende a se desligar sozinho. (Task TaskHub #2760, Opção B.)

### Adicionado
- **Encerramento automático**: o servidor agora se desliga sozinho quando a aba do
  navegador fecha — resolve o problema real de o `.ps1` continuar rodando (ocupando a
  porta 8080) até alguém fechar a janela do PowerShell na mão. Duas camadas:
  - Sinal explícito: `pagehide`/`beforeunload` no navegador disparam
    `navigator.sendBeacon('/api/shutdown')`, e o servidor encerra na hora.
  - Guarda de segurança por ausência de sinal: o navegador manda um heartbeat a cada 5s
    (`/api/heartbeat`); sem heartbeat por 20s (navegador travado/fechado à força), o
    servidor percebe o silêncio e se desliga sozinho (`Test-ShouldAutoShutdown`, pura e
    testada — mesmo padrão de `Test-RecentLocalActivity`/`Test-CacheCleanupSafe`).
  - Implementado trocando o `HttpListener.GetContext()` bloqueante por
    `BeginGetContext`/`EndGetContext` + `WaitOne` em janelas de 1s — dá ao servidor a
    chance de checar a guarda de silêncio sem exigir threads/timers novos.
- **Instalador Windows** (`installer/CloudCleaner.iss`, Inno Setup): copia os arquivos,
  cria um launcher que roda o programa **sem a janela preta do PowerShell** aparecendo
  (`installer/CloudCleaner.vbs`, com ícone próprio), e oferece **duas checkboxes**
  independentes — atalho na Área de Trabalho **e/ou** no Menu Iniciar — igual a qualquer
  instalador padrão do Windows.
- **Extra**: botão "📂 Abrir pasta" na linha do breadcrumb (subpastas) que abre o
  Explorador de Arquivos do Windows já na pasta selecionada
  (`Invoke-AbrirPastaNoExplorer`, novo endpoint `POST /api/open-folder`).
- **Testes**: 12 novos testes em `tests/Run-Tests.ps1` (watchdog de encerramento +
  abrir pasta), rodando puro/sem I/O real (mesmo padrão DI de sempre) — suíte total
  sobe para 42 (era 35, zero Pester).


Limpeza **GUARDADA** do `content_cache` do Google Drive Stream. (Follow-up de #17/PR #8.)

### Adicionado
- **`Invoke-LimpezaGuardadaGoogleDriveCache`**: implementa de fato a limpeza do `content_cache`
  do Google Drive Stream (detectado/medido desde a v1.0.1, mas nunca apagado até agora), com
  **3 salvaguardas**: (1) confirmação forte — o usuário precisa **digitar** a frase exata
  (`APAGAR CACHE`) no modal, validada de novo no backend; (2) resguardo do estado antes de apagar
  — o `content_cache` é **movido** (nunca apagado) para um backup com timestamp; (3) aborta sem
  tocar em nada se detectar atividade local recente na pasta sincronizada (possível upload
  pendente para a nuvem).
- Novas funções, todas testáveis por injeção de dependência (sem tocar em processo/disco reais
  nos testes): `Test-CacheCleanupSafe`, `Test-RecentLocalActivity`, `Get-GoogleDriveRecentActivityFiles`,
  `Backup-GoogleDriveCache`, `Restore-GoogleDriveCache`, `Get-GoogleDriveFsProcessInfo`,
  `Stop-GoogleDriveFsProcess`, `Start-GoogleDriveFsProcess`.
- Novo endpoint `POST /api/gdrive-cache-cleanup` (`{ account, confirm }`) e `/api/suggestions`
  passou a expor `googleDrive.cleanupConfirmPhrase` (fonte única da frase de confirmação).
- **Frontend**: botão **"🧹 Limpar cache guardado"** por conta detectada, modal de confirmação
  estendido com campo de **digitação obrigatória** (botão só habilita com o texto exato).
- **Testes**: `tests/GoogleDriveGuardedCleanup.Tests.ps1` — suite **Pester** (29 testes) cobrindo
  as 3 salvaguardas, incluindo a prova de reversibilidade (round-trip backup→restore contra
  pastas falsas do `TestDrive:`).

### Corrigido
- Um erro de mensagem (`throw` com travessão dentro de string interpolada) em
  `Restore-GoogleDriveCache` quebrava o parser do **Windows PowerShell 5.1** sob a codepage OEM
  850 (comum em Windows PT-BR) — corrigido usando só ASCII na mensagem. Achado ao validar a
  execução real (`-File`) no PC de destino, não só via Pester/pwsh 7.

### Nota de validação
- Desenvolvido e testado **num PC Windows real com Google Drive for Desktop instalado**
  (jump do Nelson) — a suite Pester roda inteiramente contra pastas falsas (`TestDrive:`); a
  única leitura contra o ambiente real foi checagem informativa (processo/disco), nunca
  escrita/exclusão. O caminho de "confirmação certa" (que de fato pararia o Google Drive e
  moveria o cache) foi validado só pelos testes injetados — nunca executado contra o cache real
  de ninguém.

---

## [1.1.0] – 2026-07-31
Suporte a **iCloud Drive** (iCloud for Windows). (#18)

### Adicionado
- **Detecção do iCloud Drive**: nomes de pasta padrão em `%USERPROFILE%` (`iCloud Drive` e `iCloudDrive`, cobrindo o app da Microsoft Store e o instalador MSI clássico), leitura do **registro do Windows** (`SyncRootManager`) para achar a pasta caso tenha sido **movida**, e varredura nas raízes de disco — mesmo padrão já usado para OneDrive/Google Drive. Sem iCloud instalado, a nuvem não aparece (sem erro), igual ao comportamento já existente para Google Drive ausente. Novas funções: `Get-ICloudFolderNames`, `Test-IsPlausibleWindowsPath`, `Get-ICloudPathsFromRegistry`, `Get-CaminhosICloud`.
- `Resolve-CloudInfo` ganhou o parâmetro `-ICloudRoots` e o `provider = 'icloud'` (`freeable = $true`) — o iCloud Drive usa a **mesma Cloud Files API** do OneDrive, então **reusa o mesmo motor** de liberação por atributo (`+U -P`), sem caminho novo.
- `/api/suggestions` agora retorna `icloudPaths` (lista) e, por disco, `icloudPaths`/`hasICloud`. `/api/scan` classifica caminhos do iCloud Drive no bloco `cloud`.
- **Frontend**: badge e atalhos do iCloud Drive nos cards do dashboard de discos (cor roxa, distinta de OneDrive/Google Drive).
- **Testes**: 14 novos asserts cobrindo a classificação do iCloud Drive em `Resolve-CloudInfo` (incluindo a proteção contra casar prefixo parcialmente, ex.: `iCloud DriveX` não casa com `iCloud Drive`) e as funções puras `Get-ICloudFolderNames`/`Test-IsPlausibleWindowsPath` — total do suite: **35 passou, 0 falhou**.

### Corrigido
- `Get-CaminhosOneDrive`/`Get-GoogleDriveAppData`/`Get-GoogleDriveCacheInfo` não tratavam a ausência de `$env:USERPROFILE`/`$env:LOCALAPPDATA` (variável nula) — agora guardado, evitando erro 500 em `/api/suggestions` nesse cenário.

### Fora de escopo
- **Fotos do iCloud** (armazenamento próprio, separado do iCloud Drive) — não coberto por esta entrega.

### Nota
- Sem uma máquina Windows com iCloud instalado neste ciclo de desenvolvimento para validar fisicamente; a lógica de detecção/classificação foi coberta por testes automatizados (sem depender de Windows real). Validação física pendente na máquina de destino.

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
