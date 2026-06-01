# Changelog

Todas as mudanças notáveis deste projeto serão documentadas neste arquivo.

Formato baseado em [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) e
seguindo [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
