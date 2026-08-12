#!/usr/bin/env bash
# build-installer.sh — compila o instalador Windows (.exe) do CloudCleaner
# a partir de installer/CloudCleaner.iss, usando o Inno Setup 6.
#
# Task TaskHub #6038: o CI (.github/workflows/build-installer.yml) depende de um
# token com escopo `workflow` que nenhuma credencial nossa tem hoje neste repo —
# então o build "de verdade" é este script, rodado localmente, sem depender do CI.
#
# USO
#   ./installer/build-installer.sh
#   → gera installer/dist/CloudCleaner-Setup-vX.Y.Z.exe
#
# Funciona em 3 cenários, na ordem:
#   1. Windows / Git Bash com Inno Setup instalado nativamente → usa o ISCC.exe direto.
#   2. Linux/macOS com Wine + Inno Setup instalado num prefixo Wine → usa Wine + xvfb-run.
#   3. Nenhum dos dois → falha com instruções de como preparar o ambiente (ver
#      "BOOTSTRAP DO ZERO" abaixo).
#
# VARIÁVEIS DE AMBIENTE (todas opcionais — os defaults cobrem a máquina onde este
# script foi criado; sobrescreva se seu ambiente for diferente):
#   ISCC        caminho completo do ISCC.exe (compilador do Inno Setup)
#               default: $WINEPREFIX/drive_c/Program Files (x86)/Inno Setup 6/ISCC.exe
#   WINE        caminho do binário wine
#               default: /home/claude-code/.local/wine/bin/wine (senão: `wine` do PATH)
#   WINEPREFIX  prefixo Wine onde o Inno Setup está instalado
#               default: /home/claude-code/.wine-cloudcleaner
#
# BOOTSTRAP DO ZERO (preparar uma máquina Linux nova pra compilar o instalador):
#   1. Instalar Wine (Debian/Ubuntu):
#        sudo apt-get install -y wine64 xvfb
#      (xvfb-run é usado pra rodar o instalador do Inno Setup sem precisar de um
#      display gráfico real — o Inno Setup é um app Windows GUI.)
#   2. Criar um prefixo Wine dedicado (evita misturar com outros usos do Wine):
#        export WINEPREFIX=~/.wine-cloudcleaner
#        export WINEARCH=win32
#        wine wineboot --init
#   3. Baixar o instalador do Inno Setup 6 (https://jrsoftware.org/isdl.php) e instalar
#      dentro desse prefixo:
#        wget -O /tmp/innosetup.exe https://files.jrsoftware.org/is/6/innosetup-6.4.3.exe
#        xvfb-run -a wine /tmp/innosetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
#      Isso instala o Inno Setup em:
#        $WINEPREFIX/drive_c/Program Files (x86)/Inno Setup 6/ISCC.exe
#   4. Rodar este script normalmente — ele encontra o ISCC.exe pelos defaults acima.
#
# Se preferir usar um Wine "de sistema" (não portátil) e/ou outro caminho de
# instalação do Inno Setup, exporte WINE/WINEPREFIX/ISCC antes de chamar o script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISS_FILE="$SCRIPT_DIR/CloudCleaner.iss"
DIST_DIR="$SCRIPT_DIR/dist"

if [[ ! -f "$ISS_FILE" ]]; then
    echo "ERRO: não encontrei $ISS_FILE — rode este script a partir de um checkout do repo CloudCleaner." >&2
    exit 1
fi

# Defaults desta máquina — sobrescritos por env var se já estiverem setados.
WINE="${WINE:-/home/claude-code/.local/wine/bin/wine}"
WINEPREFIX="${WINEPREFIX:-/home/claude-code/.wine-cloudcleaner}"
DEFAULT_ISCC_WINE_PATH="$WINEPREFIX/drive_c/Program Files (x86)/Inno Setup 6/ISCC.exe"
ISCC="${ISCC:-$DEFAULT_ISCC_WINE_PATH}"

run_native() {
    # Cenário 1: Windows / Git Bash com ISCC.exe já no PATH.
    if command -v ISCC.exe >/dev/null 2>&1; then
        echo "Usando ISCC.exe nativo (encontrado no PATH)..."
        ISCC.exe "$ISS_FILE"
        return 0
    fi
    return 1
}

run_wine() {
    # Cenário 2: Linux/macOS com Wine + Inno Setup num prefixo Wine.
    if [[ ! -x "$WINE" ]] && ! command -v "$WINE" >/dev/null 2>&1; then
        echo "ERRO: não encontrei o binário do Wine em '$WINE'." >&2
        echo "  → Instale o Wine ou exporte WINE=/caminho/pro/wine apontando pro binário certo." >&2
        return 1
    fi
    if [[ ! -f "$ISCC" ]]; then
        echo "ERRO: não encontrei o compilador do Inno Setup (ISCC.exe) em:" >&2
        echo "  '$ISCC'" >&2
        echo "  → O Inno Setup 6 precisa estar instalado dentro do prefixo Wine '$WINEPREFIX'." >&2
        echo "  → Veja o bloco 'BOOTSTRAP DO ZERO' no cabeçalho deste script" >&2
        echo "    ($SCRIPT_DIR/build-installer.sh) pra instalar do zero," >&2
        echo "    ou exporte ISCC=/caminho/completo/pro/ISCC.exe se ele já estiver instalado" >&2
        echo "    em outro lugar." >&2
        return 1
    fi

    echo "Compilando com Wine (WINEPREFIX=$WINEPREFIX)..."
    export WINEPREFIX
    local wine_iss
    wine_iss="$(winepath_or_fallback "$ISS_FILE")"

    # ISCC.exe é o compilador de linha de comando — não abre janela, então normalmente
    # nem precisa de display. Preferimos xvfb-run quando disponível (mais robusto em
    # ambientes sem X), mas caímos pra Wine direto se xvfb-run não estiver utilizável
    # (ex.: falta o pacote `xauth`, dependência do xvfb-run).
    if command -v xvfb-run >/dev/null 2>&1 && command -v xauth >/dev/null 2>&1; then
        xvfb-run -a "$WINE" "$ISCC" "$wine_iss"
    else
        "$WINE" "$ISCC" "$wine_iss"
    fi
}

winepath_or_fallback() {
    # ISCC.exe usa a sintaxe de switch do Windows ("/algo"), então um caminho Unix
    # começando com "/" é confundido com uma opção ("Unknown option: /home/..."). É
    # preciso converter pro formato Windows (ex.: Z:\home\user\...) via `wine winepath`
    # antes de passar pro compilador.
    local linux_path="$1"
    "$WINE" winepath -w "$linux_path" 2>/dev/null | tr -d '\r' | tail -n1 || echo "$linux_path"
}

if run_native; then
    :
elif run_wine; then
    :
else
    echo "" >&2
    echo "FALHA: não consegui compilar o instalador — nem ISCC.exe nativo, nem Wine+Inno Setup disponíveis." >&2
    echo "Veja o cabeçalho deste script ($ISS_FILE convertido pra $SCRIPT_DIR/build-installer.sh)" >&2
    echo "para instruções de bootstrap (instalar Wine + Inno Setup do zero)." >&2
    exit 1
fi

EXE_PATH=$(find "$DIST_DIR" -maxdepth 1 -iname 'CloudCleaner-Setup-v*.exe' -newer "$ISS_FILE" 2>/dev/null | head -n1)
if [[ -z "$EXE_PATH" ]]; then
    # fallback: pega o .exe mais recente em dist/, mesmo que não seja "mais novo" que o .iss
    EXE_PATH=$(find "$DIST_DIR" -maxdepth 1 -iname 'CloudCleaner-Setup-v*.exe' 2>/dev/null | sort | tail -n1)
fi

if [[ -z "$EXE_PATH" || ! -f "$EXE_PATH" ]]; then
    echo "ERRO: o compilador rodou mas não encontrei o .exe gerado em $DIST_DIR." >&2
    exit 1
fi

SIZE_HUMAN=$(du -h "$EXE_PATH" | cut -f1)
echo ""
echo "Instalador gerado com sucesso:"
echo "  Caminho: $EXE_PATH"
echo "  Tamanho: $SIZE_HUMAN"
