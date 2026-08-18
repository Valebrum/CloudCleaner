# Encoding.Tests.ps1 — guarda de encoding dos scripts PowerShell do repo.
#
# POR QUE ESTE TESTE EXISTE (task TaskHub #2760):
#   O CloudCleaner instalado no Windows do Nelson "não abria" — clicar no atalho não
#   fazia absolutamente nada: sem janela, sem erro, sem log. A causa NÃO era o launcher
#   nem o navegador: o `CloudCleaner.ps1` simplesmente NÃO ERA PARSEÁVEL pelo Windows
#   PowerShell 5.1, então nenhuma linha dele chegava a executar (por isso nem o log nem
#   a caixa de erro do próprio script — adicionados no v1.3.1 — apareciam: eles moram
#   DENTRO do arquivo que não compila).
#
#   Mecanismo exato:
#     1. O arquivo era UTF-8 SEM BOM.
#     2. O Windows PowerShell 5.1 (o que vem no Windows) lê .ps1 sem BOM usando a
#        CODEPAGE ANSI do sistema (cp1252 no Brasil) — NÃO UTF-8. (O PowerShell 7+ e o
#        pwsh do Linux assumem UTF-8, e por isso tudo passava nos nossos testes.)
#     3. O travessão "—" (U+2014) é, em UTF-8, a sequência de bytes E2 80 94. Lida como
#        cp1252 vira "â€" + o byte 0x94, que em cp1252 é U+201D — a ASPA DUPLA CURVA DE
#        FECHAMENTO (”).
#     4. O PowerShell aceita aspas curvas como delimitador de string. Resultado: a aspa
#        fantasma FECHAVA a string no meio da linha, e o parser cascateava em erro no
#        arquivo inteiro ("Token inesperado", "')' de fechamento ausente", etc.).
#
#   Ou seja: um caractere de PONTUAÇÃO dentro de um texto em português derrubava o
#   programa inteiro, em silêncio total, só na máquina do usuário final.
#
# A REGRA QUE ESTE TESTE PROTEGE:
#   Todo .ps1 do repo deve ser SEGURO para o Windows PowerShell 5.1, ou seja:
#     (a) ter BOM UTF-8 (aí o 5.1 decodifica como UTF-8 e tudo funciona), OU
#     (b) ser 100% ASCII (aí não há o que mis-decodificar).
#   Como os scripts são escritos em português (acentos, travessões), na prática a
#   opção viável é (a) — BOM UTF-8.

$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here

$pass = 0
$fail = 0
function Assert-Ok {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) {
        $script:pass++; Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green
    } else {
        $script:fail++; Write-Host ("  [FAIL] {0}" -f $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ("         {0}" -f $Detail) -ForegroundColor Red }
    }
}

$utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)

Write-Host "=== Encoding dos .ps1 (compatibilidade com Windows PowerShell 5.1) ===" -ForegroundColor Cyan

$scripts = Get-ChildItem -Path $repoRoot -Filter '*.ps1' -Recurse -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }

Assert-Ok ($scripts.Count -gt 0) 'encontrou arquivos .ps1 para verificar'

foreach ($s in $scripts) {
    $rel   = $s.FullName.Substring($repoRoot.Length).TrimStart('\', '/')
    $bytes = [System.IO.File]::ReadAllBytes($s.FullName)

    $hasBom = ($bytes.Length -ge 3 -and
               $bytes[0] -eq $utf8Bom[0] -and $bytes[1] -eq $utf8Bom[1] -and $bytes[2] -eq $utf8Bom[2])

    # Byte >= 0x80 em qualquer posição => há caractere não-ASCII no arquivo.
    $nonAscii = @($bytes | Where-Object { $_ -ge 0x80 })
    $isPureAscii = ($nonAscii.Count -eq 0)

    Assert-Ok ($hasBom -or $isPureAscii) `
        ("{0}: seguro para o Windows PowerShell 5.1 (tem BOM UTF-8 ou e' ASCII puro)" -f $rel) `
        ("arquivo tem caractere nao-ASCII e NAO tem BOM UTF-8 -> o PowerShell 5.1 vai ler como cp1252 e pode QUEBRAR O PARSE (ver cabecalho deste teste)")
}

Write-Host ""
Write-Host ("Encoding: {0} passou, {1} falhou." -f $pass, $fail) -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })

exit $(if ($fail -gt 0) { 1 } else { 0 })
