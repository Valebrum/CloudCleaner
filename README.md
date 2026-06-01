# ![OneDriveCleaner](https://img.shields.io/badge/Valebrum-OneDriveCleaner-blue) OneDriveCleaner — Analisador e Otimizador de Pastas OneDrive

![Versão](https://img.shields.io/badge/vers%C3%A3o-0.8.3-success)
![PowerShell](https://img.shields.io/badge/PowerShell-5.x%20%7C%207%2B-5391FE?logo=powershell&logoColor=white)
![Plataforma](https://img.shields.io/badge/plataforma-Windows-0078D6?logo=windows&logoColor=white)
![Licença](https://img.shields.io/badge/licen%C3%A7a-Propriet%C3%A1ria%20Valebrum%20v1.1-red)

**OneDriveCleaner** é um **analisador e otimizador de pastas OneDrive** com backend em PowerShell e uma **interface HTML visual**. Ele mostra, lado a lado, o **tamanho lógico** (total na nuvem) e o **tamanho local** (o que realmente ocupa o disco), e permite **liberar espaço** (tornar arquivos somente-nuvem) ou **deletar** — tudo com poucos cliques.

> Migrado do script `tamanhosNasPastas0.83.ps1` para um projeto público com interface gráfica web.

---

## ✨ Funcionalidades Principais

| Funcionalidade | Descrição |
|:--|:--|
| 📊 **Lógico vs. Local** | Compara o tamanho total (nuvem) com o que ocupa de fato no disco |
| ☁️ **Liberar espaço** | Torna arquivos *somente-nuvem* (`attrib +U -P`) sem excluí-los da nuvem |
| 🗑️ **Deletar arquivos** | Remove arquivos definitivamente (com modal de confirmação) |
| 📂 **Drill-down** | Clique numa subpasta para navegar e analisar mais fundo |
| 🧭 **Breadcrumb** | Navegação por trilha de pastas, com volta a qualquer nível |
| 💽 **Espaço em disco** | Barra de uso do volume e espaço livre em tempo real |
| 📈 **Barras visuais** | Proporção lógico/local por subpasta, ordenável por coluna |
| 🎯 **Auto-sugestões** | Detecta caminhos OneDrive comuns como ponto de partida |
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

| OneDriveCleaner/ | |
|------------------|-|
| `OneDriveCleaner.ps1` | Backend PowerShell: análise + servidor HTTP local |
| `index.html`          | Interface visual (HTML/CSS/JS vanilla) |
| `README.md`           | Documentação e instruções do projeto |
| `changelog.md`        | Histórico de versões |
| `LICENSE.md`          | Licença Proprietária Valebrum v1.1 |
| `docs/screenshots/`   | Capturas de tela |
| `.gitignore`          | Arquivos ignorados pelo Git |

---

## 🚀 Instalação e Uso

### 1. Clonar o repositório

```bash
git clone https://github.com/Valebrum/OneDriveCleaner.git
cd OneDriveCleaner
```

### 2. Permitir execução de scripts (uma vez)

No PowerShell:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 3. Executar o OneDriveCleaner

```powershell
powershell -ExecutionPolicy Bypass -File .\OneDriveCleaner.ps1
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

---

## 🔌 API local (para integração)

O backend expõe endpoints simples em `http://localhost:8080`:

| Método | Endpoint | Descrição |
|--------|----------|-----------|
| `GET`  | `/api/scan?path=<caminho>` | Subpastas com tamanhos lógico/local e totais |
| `GET`  | `/api/disk-free?path=<caminho>` | Espaço livre/usado do volume |
| `GET`  | `/api/suggestions` | Caminhos OneDrive detectados |
| `POST` | `/api/free-space` `{ "path": "..." }` | Libera espaço (somente-nuvem) |
| `POST` | `/api/delete` `{ "path": "..." }` | Deleta arquivos da pasta |

---

## ⚠️ Avisos Importantes

- **Deletar é irreversível** e, em pastas sincronizadas, **reflete na nuvem**. Sempre confirme o caminho no modal.
- **Liberar espaço** é seguro: os arquivos permanecem na nuvem e voltam ao disco quando abertos.
- A análise pode levar alguns segundos em pastas com **muitos arquivos** (varredura recursiva).
- Execute apenas em caminhos **seus**; a ferramenta age sobre o que o usuário do Windows tem permissão.

---

## 📜 Changelog

Veja todas as mudanças em [`changelog.md`](changelog.md).

Resumo da **v0.8.3**:

- ✅ Interface HTML visual (tema escuro Valebrum, responsiva)
- ✅ Backend PowerShell com servidor HTTP local (`HttpListener`)
- ✅ Drill-down, breadcrumb e ordenação por coluna
- ✅ Liberar espaço / deletar com confirmação
- ✅ Auto-detecção de caminhos OneDrive

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
