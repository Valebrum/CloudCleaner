# ![CloudCleaner](https://img.shields.io/badge/Valebrum-CloudCleaner-blue) CloudCleaner — Analisador e Otimizador de Pastas OneDrive e Google Drive

![Versão](https://img.shields.io/badge/vers%C3%A3o-1.0.1-success)
![PowerShell](https://img.shields.io/badge/PowerShell-5.x%20%7C%207%2B-5391FE?logo=powershell&logoColor=white)
![Plataforma](https://img.shields.io/badge/plataforma-Windows-0078D6?logo=windows&logoColor=white)
![Licença](https://img.shields.io/badge/licen%C3%A7a-Propriet%C3%A1ria%20Valebrum%20v1.1-red)

**CloudCleaner** é um **analisador e otimizador de pastas OneDrive** com backend em PowerShell e uma **interface HTML visual**. Ele mostra, lado a lado, o **tamanho lógico** (total na nuvem) e o **tamanho local** (o que realmente ocupa o disco), e permite **liberar espaço** (tornar arquivos somente-nuvem) ou **deletar** — tudo com poucos cliques.

A partir da **v1.0.1**, o CloudCleaner também **detecta o Google Drive for Desktop** (modos **Stream** e **Espelho/Mirror**), mede o cache local do Stream e impede ações que não fariam efeito nesse provedor. Veja [OneDrive vs. Google Drive](#-onedrive-vs-google-drive-mirror-vs-stream).

> Migrado do script `tamanhosNasPastas0.83.ps1` para um projeto público com interface gráfica web.

---

## ✨ Funcionalidades Principais

| Funcionalidade | Descrição |
|:--|:--|
| 📊 **Lógico vs. Local** | Compara o tamanho total (nuvem) com o que ocupa de fato no disco |
| ☁️ **Liberar espaço** | Torna arquivos *somente-nuvem* (`+U -P`) sem excluí-los da nuvem |
| 🗑️ **Deletar arquivos** | Remove arquivos definitivamente (com modal de confirmação) |
| ⏳ **Progresso ao vivo** | Barra de progresso via SSE com %, contagem, arquivo atual, ETA e **cancelar** |
| 💽 **Dashboard de discos** | Cards de todos os volumes com rótulo, uso, livre e OneDrive detectado |
| 📂 **Drill-down** | Clique numa subpasta para navegar e analisar mais fundo |
| 🧭 **Breadcrumb** | Navegação por trilha de pastas, com volta a qualquer nível |
| 📈 **Barras visuais** | Proporção lógico/local por subpasta, ordenável por coluna |
| 🌑 **Tema escuro Valebrum** | Interface responsiva (desktop e celular), sem frameworks |
| 🔒 **100% local** | Servidor HTTP temporário em `localhost:8080` — nada sai da máquina |

---

## 📌 Pré-visualização do Programa

![Tela principal](docs/screenshots/1.png)
![Análise de subpastas](docs/screenshots/2.png)

> A interface exibe o resumo do disco, totais lógico/local e a tabela de subpastas com ações por linha.

---

## 🖥️ Requisitos

- **Windows** (usa `attrib.exe` e atributos `Offline` do OneDrive)
- **Windows PowerShell 5.x** ou **PowerShell 7+**
- Navegador moderno (Edge, Chrome, Firefox…)
- Permissão para escutar em `http://localhost:8080`
- Permissão para executar scripts (veja abaixo)

---

## 🗂 Estrutura do Projeto

| CloudCleaner/ | |
|------------------|-|
| `CloudCleaner.ps1` | Backend PowerShell: análise + servidor HTTP local |
| `index.html`          | Interface visual (HTML/CSS/JS vanilla) |
| `tests/Run-Tests.ps1` | Testes (sem dependência de Pester) das funções puras |
| `README.md`           | Documentação e instruções do projeto |
| `changelog.md`        | Histórico de versões |
| `LICENSE.md`          | Licença Proprietária Valebrum v1.1 |
| `docs/screenshots/`   | Capturas de tela |
| `.gitignore`          | Arquivos ignorados pelo Git |

---

## 🚀 Instalação e Uso

### 1. Clonar o repositório

```bash
git clone https://github.com/Valebrum/CloudCleaner.git
cd CloudCleaner
```

### 2. Permitir execução de scripts (uma vez)

No PowerShell:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 3. Executar o CloudCleaner

```powershell
powershell -ExecutionPolicy Bypass -File .\CloudCleaner.ps1
```

O script inicia um servidor local e **abre o navegador automaticamente** em `http://localhost:8080`.
Para encerrar, volte ao terminal e pressione **Ctrl+C**.

### 4. Como usar

1. Cole o caminho da pasta a analisar (ou clique numa **sugestão** detectada) e clique em **🔍 Analisar**.
2. Veja o resumo: espaço livre no disco, total **lógico** vs. **local** e quanto é **liberável**.
3. Na tabela de subpastas, use os botões por linha:
   - **📂 Analisar** — entra na subpasta (drill-down).
   - **☁️ Liberar** — torna os arquivos *somente-nuvem*, liberando espaço no disco.
   - **🗑️ Deletar** — apaga os arquivos (pede confirmação no modal).
4. Use o **breadcrumb** para voltar a qualquer nível anterior.

---

## 🧠 Conceitos: Lógico vs. Local

O OneDrive (Files On-Demand) mantém arquivos *somente-nuvem* que **não ocupam espaço no disco** até serem abertos.

| Métrica | Significado |
|---------|-------------|
| **Lógico** | Tamanho total dos arquivos, como se todos estivessem baixados (a "verdade" na nuvem) |
| **Local**  | O que realmente ocupa espaço no disco agora (ignora itens *Offline* / só-na-nuvem) |
| **Liberável** | O quanto pode ser convertido para *somente-nuvem* para recuperar espaço |

**☁️ Liberar** = `attrib +U -P` → mantém na nuvem, libera o disco.
**🗑️ Deletar** = remove o arquivo → some do disco **e** da nuvem (se sincronizado).

> ⚠️ O mecanismo de **Liberar** acima vale para o **OneDrive** (e qualquer provedor que use a *Cloud Files API* do Windows). **Não** vale para o Google Drive — veja abaixo.

---

## ☁️ OneDrive vs. Google Drive (Mirror vs Stream)

O **OneDrive** usa a **Cloud Files API do Windows** (driver *Cloud Files Filter*, `cldflt`): arquivos só-na-nuvem são *placeholders* NTFS com o atributo `Offline`, e dá pra liberar/fixar com `attrib +U`/`+P`. É nisso que o CloudCleaner se apoia.

O **Google Drive for Desktop** funciona **de forma diferente** e tem **dois modos**:

| | **Stream** (padrão) | **Espelho / Mirror** |
|--|--|--|
| Onde ficam os arquivos | Volume **virtual FAT32** (rótulo `Google Drive`, ex.: `G:`/`E:`), só-na-nuvem por padrão | Pasta **local real (NTFS)**, sempre baixada |
| Atributo `Offline` (Cloud Files API) | **Não existe** — FAT32 não suporta; tudo aparece como `Normal` com **tamanho lógico** | N/A (arquivos reais) |
| `attrib +U` libera espaço? | **Não** (no-op) | **Não** (arquivo é real) |
| Footprint local de verdade | `content_cache` em `%LOCALAPPDATA%\Google\DriveFS\<conta>\content_cache` | Tamanho total dos arquivos no disco |
| Como recuperar espaço | App do Google Drive (somente-nuvem) / limpar cache | Deletar ou trocar a pasta para **Stream** |

**O que o CloudCleaner faz com o Google Drive:**

- **Detecta** o provedor por **assinatura de volume** (`VolumeName = "Google Drive"`), o que independe do idioma — funciona com `Meu Drive` ou `My Drive`.
- **Mede** o `content_cache` (o espaço local real que o Stream ocupa) e mostra no dashboard.
- **Bloqueia** a "Liberar espaço" em caminhos do Google Drive (Stream ou Mirror), porque seria um no-op que **reportaria espaço liberado falso**. A UI desabilita os botões e exibe um aviso explicativo; **Deletar** continua disponível.

> Por que não há um botão "limpar cache do Stream"? Apagar `content_cache` com o DriveFS rodando pode corromper o estado. A limpeza segura (parar o DriveFS → limpar → reiniciar) ficou como follow-up; por ora a ferramenta mede e orienta.

---

## 🔌 API local (para integração)

O backend expõe endpoints simples em `http://localhost:8080`:

| Método | Endpoint | Descrição |
|--------|----------|-----------|
| `GET`  | `/api/scan?path=<caminho>` | Subpastas com tamanhos lógico/local, totais e bloco `cloud` (`provider`, `mode`, `freeable`, `note`) |
| `GET`  | `/api/disk-free?path=<caminho>` | Espaço livre/usado do volume |
| `GET`  | `/api/suggestions` | Discos do sistema (uso por volume) + OneDrive e **Google Drive** detectados (bloco `googleDrive` com tamanho do `content_cache`) |
| `GET`  | `/api/free-space?path=<caminho>` | **SSE** — libera espaço (somente-nuvem) com progresso ao vivo. **Recusa** caminhos do Google Drive (`phase: 'error'` com explicação) |
| `GET`  | `/api/delete?path=<caminho>` | **SSE** — deleta arquivos da pasta com progresso ao vivo |

> `/api/free-space` e `/api/delete` retornam um stream **Server-Sent Events** (`text/event-stream`),
> emitindo eventos `{ phase: 'start'|'progress'|'done'|'error', current, total, currentFile, ... }`.
> Fechar a conexão (`EventSource.close()`) cancela a operação no servidor.

---

## 🧪 Testes

Os testes não dependem de Pester (rodam em PowerShell 5.x ou 7+). Eles fazem *dot-source* do script com `-NoServe` (carrega só as funções, sem subir o servidor) e validam as funções puras:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

Saída esperada: `Resultado: 21 passou, 0 falhou.` (código de saída `0`). Também imprime, de forma informativa, se há Google Drive instalado e o tamanho do `content_cache` detectado na máquina.

---

## ⚠️ Avisos Importantes

- **Deletar é irreversível** e, em pastas sincronizadas, **reflete na nuvem**. Sempre confirme o caminho no modal.
- **Liberar espaço** é seguro: os arquivos permanecem na nuvem e voltam ao disco quando abertos.
- A análise pode levar alguns segundos em pastas com **muitos arquivos** (varredura recursiva).
- Execute apenas em caminhos **seus**; a ferramenta age sobre o que o usuário do Windows tem permissão.

---

## 📜 Changelog

Veja todas as mudanças em [`changelog.md`](changelog.md).

Resumo da **v1.0.1**:

- ✅ Detecção de **Google Drive for Desktop** (Stream e Espelho) por assinatura de volume
- ✅ Medição do `content_cache` (footprint local real do modo Stream)
- ✅ Guarda contra "liberar espaço" enganoso em caminhos do Google Drive (corrige super-reporte de bytes)
- ✅ Testes sem dependência de Pester (`tests/Run-Tests.ps1`) e switch `-NoBrowser`

Resumo da **v1.0.0**:

- ✅ Barra de progresso em tempo real (SSE) com ETA e cancelar
- ✅ Dashboard de discos com uso por volume e OneDrive detectado
- ✅ Liberar espaço via API nativa Win32 (`SetFileAttributesW`)
- ✅ Interface HTML visual (tema escuro Valebrum, responsiva)
- ✅ Drill-down, breadcrumb e ordenação por coluna

---

## 🤝 Contribuição

Contribuições internas são bem-vindas. Para reportar bugs ou sugerir melhorias, abra uma **Issue** descrevendo o caso com exemplos.

---

## 📞 Suporte

- 🐛 **Bug report:** abra uma Issue
- 💡 **Sugestão:** Discussions
- 📧 **Contato:** contato@valebrum.com.br

---

## 📄 Licença

Software proprietário do **Grupo Valebrum** — Licença Proprietária v1.1. Veja [`LICENSE.md`](LICENSE.md).
Idealizador: **Nelson Brum** · Desenvolvido por **Claude + Nelson**.
