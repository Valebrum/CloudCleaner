# CloudCleaner - Analisador e Otimizador de Pastas OneDrive, iCloud Drive e Google Drive
# Idealizador: Nelson Brum
# Desenvolvedor: Claude + Nelson
# Versão: 1.3.1
# Data: 2026-08-11
#
# O que faz:
#   Analisa pastas (OneDrive-friendly), comparando tamanho LÓGICO (total na nuvem)
#   com tamanho LOCAL (ocupado no disco, ignorando itens só-na-nuvem). Permite
#   liberar espaço local (tornar somente-nuvem via attrib +U -P) ou deletar arquivos.
#
#   Detecta também o iCloud Drive (iCloud for Windows), que usa a MESMA Cloud Files
#   API do OneDrive — mesmo motor de liberação por atributo, só muda a detecção da
#   pasta sincronizada (padrão + registro do Windows, pasta pode ter sido movida).
#   Ver bloco "DETECÇÃO ICLOUD DRIVE". Fora de escopo: Fotos do iCloud.
#
#   Detecta também o Google Drive for Desktop (Mirror vs Stream). Diferente do
#   OneDrive, o Google Drive NÃO usa a Cloud Files API do Windows: o Stream monta
#   um volume virtual FAT32 (sem o atributo Offline) cujo footprint real é o
#   content_cache; o Mirror mantém cópias locais reais. Por isso a "liberação por
#   atributo" é BLOQUEADA em caminhos do Google Drive (seria no-op enganoso) — a
#   ferramenta detecta, mede o cache e orienta. Ver bloco "DETECÇÃO GOOGLE DRIVE".
#
# Arquitetura: backend PowerShell (HttpListener em localhost:8080) + interface HTML.
#
# Execução sugerida:
#   powershell -ExecutionPolicy Bypass -File .\CloudCleaner.ps1
#
# Observação: roda em Windows PowerShell 5.x ou PowerShell 7+ (Windows).
#             Requer permissão para escutar em http://localhost:8080.

# Parâmetros.
#   -NoServe   : carrega apenas as funções (sem subir o servidor HTTP), usado
#                pelos testes que fazem dot-source deste arquivo.
#   -NoBrowser : sobe o servidor mas não abre o navegador (execução headless/CI).
param(
    [switch]$NoServe,
    [switch]$NoBrowser
)

# ================================================================
# CONFIGURAÇÃO INICIAL
# ================================================================
$ErrorActionPreference = 'Stop'

$script:Port    = 8080
$script:Prefix  = "http://localhost:$($script:Port)/"
$script:Root    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# [Console]::OutputEncoding pode LANÇAR (System.IO.IOException "The handle is invalid")
# quando o processo é iniciado sem console de verdade anexado — é exatamente o caso do
# launcher instalado (task #2760/rework): wscript.exe chama "powershell.exe -WindowStyle
# Hidden", e em algumas versões/condições do Windows isso resulta em nenhum console
# alocado, não um console "só escondido". Como essa é a 1ª instrução do script, uma
# exceção aqui matava o processo por completo ANTES de qualquer log/servidor — exatamente
# o sintoma "instalei, cliquei, e não aconteceu nada". Cosmético (só afeta acentuação no
# console, que ninguém vê quando roda oculto) — não pode ser fatal.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- Diagnóstico visível (task #2760/rework: "instalei mas nada aconteceu") ------------
# O launcher roda 100% oculto (sem janela de PowerShell) — todo Write-Host, todo erro,
# tudo que antes só aparecia (ou não) numa janela preta agora também vai para um arquivo
# de log ao lado do executável, e falhas fatais mostram uma caixa de mensagem visível.
# Sem isso, "nada acontecer" na tela do usuário podia ser, na real, um erro qualquer
# (porta 8080 ocupada, permissão negada, etc.) morrendo em silêncio total.
function Get-CloudCleanerLogDir {
    # {app} pode ter sido instalado em local sem permissão de escrita pro usuário atual
    # (ex.: Program Files, se o instalador rodou elevado mas o app roda sem elevação
    # depois). Tenta gravar no diretório do script; se não der, cai para uma pasta do
    # usuário que É sempre gravável.
    $candidates = @($script:Root)
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'CloudCleaner') }
    $candidates += (Join-Path ([System.IO.Path]::GetTempPath()) 'CloudCleaner')
    foreach ($dir in $candidates) {
        if (-not $dir) { continue }
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            $probe = Join-Path $dir ('.write-test-' + [guid]::NewGuid())
            [IO.File]::WriteAllText($probe, 'ok')
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return $dir
        } catch { continue }
    }
    return $null
}
$script:LogDir      = Get-CloudCleanerLogDir
$script:LogPath      = if ($script:LogDir) { Join-Path $script:LogDir 'CloudCleaner.log' } else { $null }
$script:ErrorLogPath = if ($script:LogDir) { Join-Path $script:LogDir 'CloudCleaner-error.log' } else { $null }

# Anexa uma linha ao log de erro — NUNCA lança (log é um "melhor esforço": se até logar
# falhar, o programa não pode travar por causa disso).
function Write-CloudCleanerErrorLog {
    param([string]$Message)
    if (-not $script:ErrorLogPath) { return }
    try {
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $script:ErrorLogPath -Value "[$ts] $Message" -Encoding UTF8
    } catch {}
}

# Mostra o erro de um jeito que o usuário REALMENTE vê (o programa roda sem nenhuma
# janela — sem isso, um erro fatal é indistinguível de "nada aconteceu"). Best-effort:
# se a MessageBox não puder ser exibida (ex.: sem sessão gráfica), o log de erro
# continua sendo a rede de segurança.
function Show-CloudCleanerFatalError {
    param([string]$Context, $ErrorRecord)

    $detail  = if ($ErrorRecord) { $ErrorRecord.Exception.Message } else { 'erro desconhecido' }
    $logLine = "ERRO FATAL em '$Context': $detail"
    if ($ErrorRecord -and $ErrorRecord.ScriptStackTrace) { $logLine += "`n$($ErrorRecord.ScriptStackTrace)" }
    Write-CloudCleanerErrorLog -Message $logLine

    $userMsg = "O CloudCleaner encontrou um erro e não conseguiu iniciar.`n`n$detail"
    if ($script:ErrorLogPath) { $userMsg += "`n`nDetalhes completos em:`n$script:ErrorLogPath" }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($userMsg, 'CloudCleaner - Erro ao iniciar', `
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {
        # Sem GUI disponível (ex.: rodando em CI/headless) — o log de erro já registrou.
    }
}

# Frase de confirmação forte exigida pela limpeza GUARDADA do cache do Google Drive
# Stream (ver bloco "LIMPEZA GUARDADA DO CACHE"). Fica num só lugar (backend) e a UI
# a lê de /api/suggestions — nunca hardcoded duas vezes.
$script:GDriveCleanupConfirmPhrase = 'APAGAR CACHE'

# API nativa Win32 para definir atributos de nuvem (UNPINNED/PINNED), que o enum
# [System.IO.FileAttributes] do .NET rejeita. É exatamente o que o attrib.exe faz.
# Envolvido em try/catch: se a compilação do P/Invoke falhar (ex.: AMSI/antivírus
# bloqueando Add-Type), o erro fica registrado em vez de matar o processo inteiro —
# o servidor HTTP e as demais funções (análise, listagem) não dependem deste tipo.
try {
    if (-not ('Win32.NativeFs' -as [type])) {
        Add-Type -Namespace Win32 -Name NativeFs -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool SetFileAttributesW(string lpFileName, uint dwFileAttributes);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint GetFileAttributesW(string lpFileName);
'@
    }
} catch {
    Write-CloudCleanerErrorLog -Message "Falha ao registrar Win32.NativeFs (liberação de espaço por atributo pode não funcionar): $($_.Exception.Message)"
}

# ================================================================
# FUNÇÕES DE FORMATAÇÃO (preservadas do script original)
# ================================================================
function Format-Tamanho {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    elseif ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    elseif ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    else { return ("{0} B" -f $Bytes) }
}

function Format-Numero {
    param([long]$Valor)
    return $Valor.ToString("N0", [System.Globalization.CultureInfo]::GetCultureInfo("pt-BR"))
}

# ================================================================
# LÓGICA DE ANÁLISE (refatorada do script original)
# ================================================================

# Retorna o espaço livre (bytes) do volume que contém o caminho informado.
function Get-DiscoLivre {
    param([Parameter(Mandatory)][string]$Caminho)
    try {
        $drv = (Get-Item -LiteralPath $Caminho -ErrorAction Stop).PSDrive
        if ($drv) {
            return [PSCustomObject]@{
                Drive         = $drv.Name + ':'
                FreeBytes     = [int64]$drv.Free
                FreeFormatted = Format-Tamanho ([int64]$drv.Free)
                TotalBytes    = [int64]($drv.Free + $drv.Used)
                UsedBytes     = [int64]$drv.Used
            }
        }
    } catch {
        return $null
    }
}

# Analisa as subpastas diretas de um caminho.
# Para cada subpasta: contagem de arquivos, tamanho lógico e tamanho local.
# Retorna objeto com: path, disk (livre), subfolders[], totals.
function Get-AnaliseDePasta {
    param([Parameter(Mandatory)][string]$Caminho)

    if (-not (Test-Path -LiteralPath $Caminho)) {
        throw "Caminho inválido: $Caminho"
    }

    $subpastas = Get-ChildItem -LiteralPath $Caminho -Directory -Force -ErrorAction Stop

    $i = 1
    $subfolders = foreach ($p in $subpastas) {
        $arquivos = Get-ChildItem -LiteralPath $p.FullName -Recurse -File -Force -ErrorAction SilentlyContinue
        $qtde = ($arquivos | Measure-Object).Count
        $logico = ($arquivos | Measure-Object -Property Length -Sum).Sum; if (-not $logico) { $logico = 0 }
        # "Local" = arquivos que NÃO estão Offline (só-na-nuvem)
        $locais = $arquivos | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Offline) }
        $local = ($locais | Measure-Object -Property Length -Sum).Sum; if (-not $local) { $local = 0 }

        [PSCustomObject]@{
            index            = $i++
            name             = $p.Name
            path             = $p.FullName
            files            = $qtde
            filesFormatted   = Format-Numero $qtde
            logicalBytes     = [int64]$logico
            logicalFormatted = Format-Tamanho $logico
            localBytes       = [int64]$local
            localFormatted   = Format-Tamanho $local
            localPercent     = if ($logico -gt 0) { [math]::Round(($local / $logico) * 100, 1) } else { 0 }
        }
    }

    # Totais (todos os arquivos recursivamente sob o caminho)
    $todos = Get-ChildItem -LiteralPath $Caminho -Recurse -File -Force -ErrorAction SilentlyContinue
    $totQtde   = ($todos | Measure-Object).Count
    $totLogico = ($todos | Measure-Object -Property Length -Sum).Sum; if (-not $totLogico) { $totLogico = 0 }
    $totLocal  = ($todos | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Offline) } | Measure-Object -Property Length -Sum).Sum
    if (-not $totLocal) { $totLocal = 0 }

    return [PSCustomObject]@{
        path       = $Caminho
        parent     = (Split-Path -Parent $Caminho)
        disk       = (Get-DiscoLivre -Caminho $Caminho)
        cloud      = (Get-PathCloudInfo -Path $Caminho)
        subfolders = @($subfolders)
        totals     = [PSCustomObject]@{
            files            = $totQtde
            filesFormatted   = Format-Numero $totQtde
            logicalBytes     = [int64]$totLogico
            logicalFormatted = Format-Tamanho $totLogico
            localBytes       = [int64]$totLocal
            localFormatted   = Format-Tamanho $totLocal
            localPercent     = if ($totLogico -gt 0) { [math]::Round(($totLocal / $totLogico) * 100, 1) } else { 0 }
        }
    }
}

# Atributos de nuvem do Windows (Files On-Demand). Definir UNPINNED equivale a "attrib +U".
$script:FILE_ATTRIBUTE_PINNED   = 0x00080000
$script:FILE_ATTRIBUTE_UNPINNED = 0x00100000

# (PURA) Calcula o novo valor de atributos para tornar um arquivo "somente-nuvem":
# liga UNPINNED (+U), desliga PINNED (-P) e preserva os demais bits (32 bits).
# Extraída para ser testável sem tocar no filesystem.
function Get-UnpinnedAttributeValue {
    param([Parameter(Mandatory)][uint64]$Current)
    return [uint32](($Current -bor $script:FILE_ATTRIBUTE_UNPINNED) -band (0xFFFFFFFF -bxor $script:FILE_ATTRIBUTE_PINNED))
}

# Versão com PROGRESSO (SSE) da liberação de espaço. Processa arquivo a arquivo,
# emitindo eventos de progresso via Send-SseData. Se o cliente desconectar
# (cancelamento), Send-SseData retorna $false e interrompemos o processamento.
function Invoke-LiberarEspacoStream {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Caminho
    )

    if (-not (Test-Path -LiteralPath $Caminho)) {
        Send-SseData -Response $Response -Object @{ phase = 'error'; message = "Caminho inválido: $Caminho" } | Out-Null
        return
    }

    # Guarda: o Google Drive (Stream/Mirror) NÃO usa a Cloud Files API. Liberar por
    # atributo seria no-op e super-reportaria bytes. Recusamos com mensagem clara.
    $cloud = Get-PathCloudInfo -Path $Caminho
    if (-not $cloud.freeable) {
        Send-SseData -Response $Response -Object @{ phase = 'error'; message = $cloud.note } | Out-Null
        return
    }

    $localFiles = @(Get-ChildItem -LiteralPath $Caminho -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Offline) })
    $total = $localFiles.Count
    $bytesTotal = ($localFiles | Measure-Object -Property Length -Sum).Sum; if (-not $bytesTotal) { $bytesTotal = 0 }

    if (-not (Send-SseData -Response $Response -Object @{ phase = 'start'; current = 0; total = $total; totalBytes = [int64]$bytesTotal })) { return }

    if ($total -eq 0) {
        Send-SseData -Response $Response -Object @{ phase = 'done'; current = 0; total = 0; freedFiles = 0; freedBytes = 0; freedFormatted = (Format-Tamanho 0); message = 'Nenhum arquivo local para liberar.' } | Out-Null
        return
    }

    $current = 0; $freedBytes = 0
    $step = [Math]::Max(1, [Math]::Floor($total / 200))

    $INVALID = [uint32]'0xFFFFFFFF'
    foreach ($f in $localFiles) {
        try {
            $cur = [Win32.NativeFs]::GetFileAttributesW($f.FullName)
            if ($cur -ne $INVALID) {
                # +U (somente-nuvem) e -P (despinar), preservando os demais atributos.
                $new = Get-UnpinnedAttributeValue -Current ([uint64]$cur)
                if ([Win32.NativeFs]::SetFileAttributesW($f.FullName, [uint32]$new)) {
                    $freedBytes += $f.Length
                }
            }
        } catch { }
        $current++

        if ($current % $step -eq 0 -or $current -eq $total) {
            $ok = Send-SseData -Response $Response -Object @{ phase = 'progress'; current = $current; total = $total; currentFile = $f.Name; freedBytes = [int64]$freedBytes }
            if (-not $ok) { return }  # cliente cancelou
        }
    }

    Send-SseData -Response $Response -Object @{
        phase          = 'done'
        current        = $current
        total          = $total
        freedFiles     = $current
        freedBytes     = [int64]$freedBytes
        freedFormatted = (Format-Tamanho $freedBytes)
        message        = ("Convertidos para somente-nuvem: {0} arquivo(s). Estimativa liberada: {1}." -f (Format-Numero $current), (Format-Tamanho $freedBytes))
    } | Out-Null
}

# Versão com PROGRESSO (SSE) da exclusão. Deleta arquivo a arquivo emitindo progresso.
function Invoke-DeletarStream {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Caminho
    )

    if (-not (Test-Path -LiteralPath $Caminho)) {
        Send-SseData -Response $Response -Object @{ phase = 'error'; message = "Caminho inválido: $Caminho" } | Out-Null
        return
    }

    $files = @(Get-ChildItem -LiteralPath $Caminho -Recurse -File -Force -ErrorAction SilentlyContinue)
    $total = $files.Count

    if (-not (Send-SseData -Response $Response -Object @{ phase = 'start'; current = 0; total = $total })) { return }

    if ($total -eq 0) {
        Send-SseData -Response $Response -Object @{ phase = 'done'; current = 0; total = 0; deletedFiles = 0; message = 'Nada a excluir.' } | Out-Null
        return
    }

    $current = 0
    $step = [Math]::Max(1, [Math]::Floor($total / 200))

    foreach ($f in $files) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { }
        $current++

        if ($current % $step -eq 0 -or $current -eq $total) {
            $ok = Send-SseData -Response $Response -Object @{ phase = 'progress'; current = $current; total = $total; currentFile = $f.Name }
            if (-not $ok) { return }  # cliente cancelou
        }
    }

    Send-SseData -Response $Response -Object @{
        phase        = 'done'
        current      = $current
        total        = $total
        deletedFiles = $current
        message      = ("Excluídos {0} arquivo(s) em: {1}" -f (Format-Numero $current), $Caminho)
    } | Out-Null
}

# Detecta caminhos OneDrive existentes na máquina (variáveis de ambiente + varredura).
# $Roots: raízes adicionais (ex.: raízes de cada drive) onde procurar pastas "OneDrive*".
function Get-CaminhosOneDrive {
    param([string[]]$Roots = @())
    $cands = @()
    foreach ($e in @('OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')) {
        $v = [Environment]::GetEnvironmentVariable($e)
        if ($v) { $cands += $v }
    }
    if ($env:USERPROFILE) { $cands += (Join-Path $env:USERPROFILE 'OneDrive') }

    # Procura pastas "OneDrive*" no perfil do usuário e na raiz de cada drive informado.
    $searchRoots = @($env:USERPROFILE) + $Roots
    foreach ($r in ($searchRoots | Where-Object { $_ } | Select-Object -Unique)) {
        Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'OneDrive*' } |
            ForEach-Object { $cands += $_.FullName }
    }

    return @($cands | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

# ================================================================
# DETECÇÃO GOOGLE DRIVE (Google Drive for Desktop — Mirror vs Stream)
# ================================================================
# Diferente do OneDrive, o Google Drive for Desktop NÃO usa a Cloud Files API do
# Windows (placeholders + atributo Offline + pin/unpin). São dois modos:
#
#   • STREAM  — monta um volume VIRTUAL (padrão G:; nesta máquina, E:) com
#               FileSystem FAT32 e rótulo "Google Drive". Os arquivos aparecem
#               com TAMANHO LÓGICO e atributo "Normal" — FAT32 não suporta o bit
#               Offline. O que ocupa disco de verdade é o cache em
#               %LOCALAPPDATA%\Google\DriveFS\<conta>\content_cache. Logo,
#               'attrib +U' / SetFileAttributesW(UNPINNED) NÃO libera nada aqui.
#   • MIRROR  — sincroniza uma pasta local REAL (NTFS). Todo arquivo é cópia
#               local; só se recupera espaço deletando (reflete na nuvem) ou
#               trocando a pasta para Stream nas configurações do Google.
#
# Por isso o CloudCleaner DETECTA o Google Drive, mede o footprint real (cache) e
# BLOQUEIA a "liberação por atributo" nesses caminhos (seria no-op enganoso e
# super-reportaria bytes liberados).

# (PURA) Assinatura do volume virtual do Google Drive Stream. O volume DriveFS
# sempre se apresenta com rótulo "Google Drive" (independe do idioma do Windows,
# por isso não dependemos do nome localizado "Meu Drive"/"My Drive").
function Test-IsGoogleDriveStreamVolume {
    param([string]$Label, [string]$FileSystem)
    return (([string]$Label).Trim() -ieq 'Google Drive')
}

# Nomes (localizados) das pastas-raiz do Google Drive.
$script:GDriveMyDriveNames = @('My Drive', 'Meu Drive')
$script:GDriveSharedNames  = @('Shared drives', 'Drives compartilhados')
$script:GDriveFolderNames  = @('My Drive', 'Meu Drive', 'Google Drive')

# Caminho base do app (a existência indica Google Drive for Desktop instalado).
function Get-GoogleDriveAppData {
    if (-not $env:LOCALAPPDATA) { return $null }
    return (Join-Path $env:LOCALAPPDATA 'Google\DriveFS')
}

# Volumes virtuais do Google Drive Stream presentes na máquina.
function Get-GoogleDriveStreamVolumes {
    $vols = @()
    try {
        foreach ($d in (Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
            if (Test-IsGoogleDriveStreamVolume -Label $d.VolumeName -FileSystem $d.FileSystem) {
                $vols += [PSCustomObject]@{ letter = $d.DeviceID; root = ($d.DeviceID + '\') }
            }
        }
    } catch {}
    return @($vols)
}

# Mede o content_cache (footprint local REAL do modo Stream) por conta.
function Get-GoogleDriveCacheInfo {
    $base = Get-GoogleDriveAppData
    $accounts = @()
    $total = [int64]0
    if ($base -and (Test-Path -LiteralPath $base)) {
        Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+$' } |
            ForEach-Object {
                $cc = Join-Path $_.FullName 'content_cache'
                $bytes = [int64]0
                if (Test-Path -LiteralPath $cc) {
                    $sum = (Get-ChildItem -LiteralPath $cc -Recurse -File -Force -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum).Sum
                    if ($sum) { $bytes = [int64]$sum }
                }
                $total += $bytes
                $accounts += [PSCustomObject]@{
                    account        = $_.Name
                    cacheBytes     = $bytes
                    cacheFormatted = Format-Tamanho $bytes
                }
            }
    }
    return [PSCustomObject]@{
        installed      = [bool]($base -and (Test-Path -LiteralPath $base))
        totalBytes     = [int64]$total
        totalFormatted = Format-Tamanho $total
        accounts       = @($accounts)
    }
}

# Detecta caminhos do Google Drive: raízes Stream (do volume virtual) e pastas
# Mirror (varredura por assinatura de nome em volumes normais).
# $Roots: raízes extras a varrer (ex.: raiz de cada drive). Retorna [{ path, mode }].
function Get-CaminhosGoogleDrive {
    param([string[]]$Roots = @())
    $result = @()
    $streamRootSet = @{}

    # --- STREAM: volume virtual "Google Drive" (FAT32) ---
    foreach ($v in (Get-GoogleDriveStreamVolumes)) {
        $streamRootSet[$v.root.ToUpperInvariant()] = $true
        $childAdded = $false
        foreach ($n in ($script:GDriveMyDriveNames + $script:GDriveSharedNames)) {
            $p = Join-Path $v.root $n
            if (Test-Path -LiteralPath $p) {
                $result += [PSCustomObject]@{ path = $p; mode = 'stream' }
                $childAdded = $true
            }
        }
        if (-not $childAdded) {
            $result += [PSCustomObject]@{ path = $v.root; mode = 'stream' }
        }
    }

    # --- MIRROR: pastas reais "My Drive"/"Meu Drive"/"Google Drive" em volumes normais ---
    $searchRoots = @($env:USERPROFILE) + $Roots
    foreach ($r in ($searchRoots | Where-Object { $_ } | Select-Object -Unique)) {
        $rUp = ($r.TrimEnd('\') + '\').ToUpperInvariant()
        if ($streamRootSet.ContainsKey($rUp)) { continue }  # pula o próprio volume Stream
        foreach ($n in $script:GDriveFolderNames) {
            $p = Join-Path $r $n
            if ((Test-Path -LiteralPath $p) -and -not ($result | Where-Object { $_.path -ieq $p })) {
                $result += [PSCustomObject]@{ path = $p; mode = 'mirror' }
            }
        }
    }

    return @($result)
}

# ================================================================
# LIMPEZA GUARDADA DO CACHE (content_cache) — Google Drive Stream
# ================================================================
# Follow-up da detecção acima (#17/PR #8, que parou de propósito em detectar/medir/
# orientar): implementa a limpeza de fato do content_cache, mas GUARDADA por três
# salvaguardas exigidas pela task #327:
#
#   1) Confirmação FORTE: exige digitar literalmente a frase em $script:GDriveCleanupConfirmPhrase
#      (checada tanto no backend — fonte da verdade — quanto na UI).
#   2) Resguardo do estado ANTES de apagar: o content_cache não é apagado, é MOVIDO
#      (Move-Item) para uma pasta de backup com timestamp ao lado dele. O Google Drive
#      reconstrói o cache sozinho ao reiniciar; se algo der errado, o backup volta ao
#      lugar com Restore-GoogleDriveCache.
#   3) Aborta se houver risco de edição local não sincronizada: antes de tocar em
#      qualquer coisa, varre a pasta montada (Stream) por arquivos escritos dentro de
#      uma janela de graça recente — se achar, ABORTA sem mexer em nada (mais vale
#      pedir para tentar de novo do que arriscar perder um upload pendente).
#
# Todas as funções de decisão (Test-*) são PURAS (sem I/O) e testáveis por Pester sem
# tocar em disco/processo real. As de I/O (Backup-/Restore-/Get-.../Stop-/Start-...)
# são simples o bastante para serem testadas com pastas FALSAS (TestDrive: do Pester)
# ou injetadas via scriptblock no orquestrador `Invoke-LimpezaGuardadaGoogleDriveCache`.

# (PURA) Decide se há sinal de atividade local recente (possível upload pendente) numa
# lista de arquivos já coletada. Recebe o "agora" e a janela de graça como parâmetros
# (nunca lê o relógio internamente) para ser 100% determinística em teste.
function Test-RecentLocalActivity {
    param(
        [AllowEmptyCollection()][object[]]$Files = @(),
        [Parameter(Mandatory)][DateTime]$NowUtc,
        [Parameter(Mandatory)][int]$GraceWindowSeconds
    )
    foreach ($f in $Files) {
        if (-not $f) { continue }
        $age = ($NowUtc - $f.LastWriteTimeUtc).TotalSeconds
        if ($age -ge 0 -and $age -lt $GraceWindowSeconds) { return $true }
    }
    return $false
}

# (PURA) Gate único de decisão da limpeza guardada — concentra as 3 salvaguardas numa
# função sem I/O, fácil de testar em todas as combinações. Retorna { safe, reason }.
function Test-CacheCleanupSafe {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Confirm,
        [Parameter(Mandatory)][bool]$HasRecentActivity,
        [Parameter(Mandatory)][bool]$DriveFsStopped
    )
    if ($Confirm -ne $script:GDriveCleanupConfirmPhrase) {
        return [PSCustomObject]@{
            safe   = $false
            reason = "Confirmação inválida. Digite exatamente `"$($script:GDriveCleanupConfirmPhrase)`" para prosseguir."
        }
    }
    if ($HasRecentActivity) {
        return [PSCustomObject]@{
            safe   = $false
            reason = 'Atividade local recente detectada — pode haver upload pendente para a nuvem. Abortado por segurança; confira se o Google Drive está "Atualizado" e tente novamente.'
        }
    }
    if (-not $DriveFsStopped) {
        return [PSCustomObject]@{
            safe   = $false
            reason = 'Não foi possível parar o Google Drive com segurança. Abortado sem apagar nada.'
        }
    }
    return [PSCustomObject]@{ safe = $true; reason = '' }
}

# (I/O) Lista arquivos da pasta montada do Drive (Stream) com LastWriteTimeUtc, usados
# como sinal de atividade recente. Pasta ausente/inacessível => lista vazia (sem erro) —
# quem decide o que isso significa é Test-RecentLocalActivity/Test-CacheCleanupSafe.
function Get-GoogleDriveRecentActivityFiles {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue |
              Select-Object FullName, LastWriteTimeUtc)
}

# (I/O) Estado atual do processo do DriveFS: se está rodando e o caminho do executável
# (para conseguir reiniciar depois de parar). Best-effort: numa máquina sem Google Drive
# instalado, volta "não rodando" sem erro.
function Get-GoogleDriveFsProcessInfo {
    $p = Get-Process -Name 'GoogleDriveFS' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return [PSCustomObject]@{ running = $false; path = $null } }
    $exePath = $null
    try { $exePath = $p.Path } catch {}
    return [PSCustomObject]@{ running = $true; path = $exePath }
}

# (I/O) Para o(s) processo(s) do DriveFS e espera até $TimeoutSeconds para confirmar
# que saiu — apagar o content_cache com o processo vivo pode corromper o estado dele.
# Sem processo rodando já conta como "parado com sucesso" (idempotente).
function Stop-GoogleDriveFsProcess {
    param([int]$TimeoutSeconds = 20)
    $procs = @(Get-Process -Name 'GoogleDriveFS' -ErrorAction SilentlyContinue)
    if (-not $procs) { return $true }
    foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {} }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Name 'GoogleDriveFS' -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return -not [bool](Get-Process -Name 'GoogleDriveFS' -ErrorAction SilentlyContinue)
}

# (I/O) Reinicia o DriveFS a partir do executável já detectado antes de pará-lo.
function Start-GoogleDriveFsProcess {
    param([Parameter(Mandatory)][string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) {
        throw "Executável do Google Drive não encontrado em: $ExePath"
    }
    Start-Process -FilePath $ExePath | Out-Null
}

# (I/O) Resguardo do estado: MOVE (nunca apaga) o content_cache para uma pasta de
# backup com timestamp, ao lado dele. É o que torna a limpeza reversível — o Google
# Drive reconstrói o content_cache sozinho a partir da nuvem quando reinicia; se algo
# der errado, Restore-GoogleDriveCache devolve o backup ao lugar original.
function Backup-GoogleDriveCache {
    param(
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][string]$BackupRoot,
        [scriptblock]$NowProvider = { [DateTime]::Now }
    )
    if (-not (Test-Path -LiteralPath $CacheDir)) {
        throw "content_cache não encontrado em: $CacheDir"
    }
    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }
    $stamp = (& $NowProvider).ToString('yyyyMMdd-HHmmss')
    $dest  = Join-Path $BackupRoot "content_cache.bak-$stamp"
    if (Test-Path -LiteralPath $dest) {
        throw "Destino de backup já existe: $dest"
    }
    Move-Item -LiteralPath $CacheDir -Destination $dest -Force
    return $dest
}

# (I/O) Reverte Backup-GoogleDriveCache: move o backup de volta para o lugar original
# do content_cache. É a prova de reversibilidade exigida pela task — coberta em teste
# com pastas falsas (TestDrive:), nunca contra o cache real de ninguém.
function Restore-GoogleDriveCache {
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$CacheDir
    )
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        throw "Backup não encontrado em: $BackupPath"
    }
    if (Test-Path -LiteralPath $CacheDir) {
        throw "Ja existe um content_cache em $CacheDir - remova ou renomeie antes de restaurar."
    }
    Move-Item -LiteralPath $BackupPath -Destination $CacheDir -Force
    return $CacheDir
}

# Orquestrador: aplica as 3 salvaguardas, na ordem certa, e só então parar->mover->
# reiniciar. Todas as dependências de I/O entram via scriptblock injetável — os testes
# passam fakes e nunca tocam em processo/disco reais; o uso normal (endpoint HTTP) usa
# os defaults, que chamam as funções de I/O de verdade.
function Invoke-LimpezaGuardadaGoogleDriveCache {
    param(
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Confirm,
        [string]$BackupRoot,
        [string]$MountRoot,
        [int]$GraceWindowSeconds = 900,
        [scriptblock]$NowProvider       = { [DateTime]::UtcNow },
        [scriptblock]$GetRecentActivity = { param($Root) Get-GoogleDriveRecentActivityFiles -Root $Root },
        [scriptblock]$GetDriveFsInfo    = { Get-GoogleDriveFsProcessInfo },
        [scriptblock]$StopDriveFs       = { Stop-GoogleDriveFsProcess },
        [scriptblock]$StartDriveFs      = { param($ExePath) Start-GoogleDriveFsProcess -ExePath $ExePath }
    )

    function New-ResultadoLimpeza {
        param([bool]$Success, [bool]$Aborted, [string]$Reason, $BackupPath = $null, [bool]$Restarted = $false)
        return [PSCustomObject]@{
            success    = $Success
            aborted    = $Aborted
            reason     = $Reason
            backupPath = $BackupPath
            restarted  = $Restarted
        }
    }

    if (-not $BackupRoot) { $BackupRoot = Split-Path -Parent $CacheDir }

    # Gate 1 — atividade local recente, verificada ANTES de tocar em qualquer coisa
    # (não para o DriveFS à toa se já vamos abortar por outro motivo).
    $recentFiles = if ($MountRoot) { @(& $GetRecentActivity $MountRoot) } else { @() }
    $hasRecent = Test-RecentLocalActivity -Files $recentFiles -NowUtc (& $NowProvider) -GraceWindowSeconds $GraceWindowSeconds

    $preGate = Test-CacheCleanupSafe -Confirm $Confirm -HasRecentActivity $hasRecent -DriveFsStopped $true
    if (-not $preGate.safe) {
        return New-ResultadoLimpeza $false $true $preGate.reason
    }

    # Gate 2 — para o DriveFS de verdade (apagar com ele rodando pode corromper estado).
    $fsInfo  = & $GetDriveFsInfo
    $stopped = [bool](& $StopDriveFs)
    $postGate = Test-CacheCleanupSafe -Confirm $Confirm -HasRecentActivity $false -DriveFsStopped $stopped
    if (-not $postGate.safe) {
        if ($fsInfo.path) { try { & $StartDriveFs $fsInfo.path } catch {} }
        return New-ResultadoLimpeza $false $true $postGate.reason
    }

    # Resguardo do estado (move, não apaga) — só então o cache "some" do lugar original.
    try {
        $backupPath = Backup-GoogleDriveCache -CacheDir $CacheDir -BackupRoot $BackupRoot -NowProvider $NowProvider
    } catch {
        if ($fsInfo.path) { try { & $StartDriveFs $fsInfo.path } catch {} }
        return New-ResultadoLimpeza $false $true "Falha ao criar o resguardo: $($_.Exception.Message)"
    }

    $restarted = $false
    if ($fsInfo.path) {
        try { & $StartDriveFs $fsInfo.path; $restarted = $true } catch {}
    }

    return New-ResultadoLimpeza $true $false '' $backupPath $restarted
}

# ================================================================
# ENCERRAMENTO AUTOMÁTICO (a aba fecha -> o programa se desliga sozinho)
# ================================================================
# Problema real (task #2760): o script só parava quando alguém fechava a janela do
# PowerShell na mão — fechar só a aba do navegador não avisava nada, e o processo
# ficava rodando à toa, ocupando a porta 8080. Duas camadas, as duas dentro da MESMA
# arquitetura (HttpListener + HTML/JS puro, sem framework novo):
#
#   1) SINAL EXPLÍCITO: o navegador avisa quando a aba fecha de verdade (evento
#      'pagehide' + navigator.sendBeacon para /api/shutdown, ver index.html) — o
#      servidor recebe o aviso e encerra na hora.
#   2) GUARDA POR AUSÊNCIA DE SINAL: o navegador manda um "heartbeat" periódico
#      (/api/heartbeat) enquanto a aba está aberta. Se o navegador travar ou for
#      fechado à força (sem o evento 1 disparar), os heartbeats param de chegar —
#      o servidor percebe o silêncio e se desliga sozinho depois de alguns segundos,
#      sem depender de mais nenhum aviso.
#
# Test-ShouldAutoShutdown é a decisão PURA (sem I/O, sem ler relógio internamente),
# no mesmo padrão de Test-RecentLocalActivity/Test-CacheCleanupSafe: recebe o
# "agora" e o último sinal como parâmetros, para ser 100% determinística em teste.

# Janela de silêncio (segundos) sem heartbeat antes do encerramento automático. O
# frontend manda heartbeat a cada 5s (ver index.html) — 20s tolera algumas falhas
# de rede/GC sem derrubar o servidor à toa.
$script:HeartbeatTimeoutSeconds = 20

# (PURA) Decide se o servidor deve encerrar por ausência de sinal do navegador.
function Test-ShouldAutoShutdown {
    param(
        [Parameter(Mandatory)][DateTime]$LastSignalUtc,
        [Parameter(Mandatory)][DateTime]$NowUtc,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $elapsed = ($NowUtc - $LastSignalUtc).TotalSeconds
    if ($elapsed -lt 0) { return $false }  # relógio "andou pra trás": nunca conta como silêncio
    return ($elapsed -ge $TimeoutSeconds)
}

# ================================================================
# EXTRA: ABRIR PASTA NO EXPLORADOR DE ARQUIVOS (sugestão do Nelson, task #2760)
# ================================================================
# Botão na linha de subpastas que abre o Explorador do Windows já na pasta selecionada.
# StartProcess é injetável (mesmo padrão de Start-/Stop-GoogleDriveFsProcess) — em teste
# nunca dispara um processo real, só confirma o gate de caminho + o repasse do argumento.
function Invoke-AbrirPastaNoExplorer {
    param(
        [Parameter(Mandatory)][string]$Caminho,
        [scriptblock]$StartProcess = { param($p) Start-Process -FilePath 'explorer.exe' -ArgumentList @($p) | Out-Null }
    )
    if (-not (Test-Path -LiteralPath $Caminho)) {
        throw "Caminho inválido: $Caminho"
    }
    & $StartProcess $Caminho
}

# ================================================================
# DETECÇÃO ICLOUD DRIVE (iCloud for Windows)
# ================================================================
# O iCloud for Windows usa a MESMA Cloud Files API do OneDrive (placeholders NTFS +
# atributo Offline, pin/unpin via SetFileAttributesW) — por isso a liberação de
# espaço REUSA o motor já existente (Invoke-LiberarEspacoStream / Get-UnpinnedAttributeValue),
# sem caminho novo. O que muda é só a DETECÇÃO da pasta sincronizada:
#
#   • Nome padrão: "iCloud Drive" (com espaço; instalador via Microsoft Store,
#     iCloud 14+) ou "iCloudDrive" (sem espaço; instalador MSI clássico mais antigo).
#   • A pasta pode ter sido MOVIDA pelo usuário (o próprio app do iCloud permite
#     "Change..." o destino) — por isso não assumimos caminho fixo: além dos nomes
#     padrão em %USERPROFILE%, tentamos ler o destino real no registro do Windows
#     (SyncRootManager, o mesmo mecanismo de registro que QUALQUER provedor Files
#     On-Demand usa para se anunciar ao Explorer) e também varremos as raízes de
#     disco informadas, como já é feito para OneDrive/Google Drive.
#   • Se nada for encontrado (iCloud não instalado/nunca configurado), a lista volta
#     vazia — sem erro — e a nuvem simplesmente não aparece na tela, igual ao
#     comportamento já existente para Google Drive ausente.

# (PURA) Nomes de pasta conhecidos do iCloud Drive no Windows, sem I/O — usados como
# candidatos padrão e como filtro de varredura.
function Get-ICloudFolderNames {
    return @('iCloud Drive', 'iCloudDrive')
}

# (PURA) Valida se um valor plausivelmente representa um caminho absoluto do Windows
# (ex.: um valor lido do registro). Sem I/O — protege contra valores vazios/relativos/
# de outro SO antes de gastar um Test-Path.
function Test-IsPlausibleWindowsPath {
    param([AllowNull()][string]$Value)
    return [bool]($Value -and ($Value -match '^[A-Za-z]:\\'))
}

# Lê, na medida do possível, o destino real da pasta do iCloud Drive registrado no
# Windows como "sync root" (SyncRootManager) — o mesmo mecanismo de registro que
# QUALQUER provedor Files On-Demand (OneDrive, iCloud, Dropbox...) usa para anunciar
# sua pasta sincronizada ao Explorer. Cobre o caso de a pasta ter sido MOVIDA para um
# local não-padrão. Best-effort: numa máquina sem iCloud, sem o driver Cloud Filter,
# ou fora do Windows, a chave simplesmente não existe — retorna lista vazia, sem erro.
function Get-ICloudPathsFromRegistry {
    $syncRootKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager'
    $found = @()
    if (-not (Test-Path -LiteralPath $syncRootKey -ErrorAction SilentlyContinue)) { return @() }
    try {
        $providerKeys = Get-ChildItem -LiteralPath $syncRootKey -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'iCloudDrive*' -or $_.PSChildName -like '*iCloud*Drive*' }
        foreach ($pk in $providerKeys) {
            # O caminho local pode estar num valor da própria chave do provedor...
            try {
                $props = Get-ItemProperty -LiteralPath $pk.PSPath -ErrorAction SilentlyContinue
                foreach ($name in @('UserSyncRoot', 'SyncRootPath', 'MountPoint')) {
                    if ($props -and $props.PSObject.Properties[$name]) { $found += [string]$props.$name }
                }
            } catch {}
            # ...ou numa subchave "UserSyncRoots\<SID>" (padrão documentado do Windows
            # para sync roots por usuário).
            try {
                $usrKey = Join-Path $pk.PSPath 'UserSyncRoots'
                if (Test-Path -LiteralPath $usrKey -ErrorAction SilentlyContinue) {
                    Get-ChildItem -LiteralPath $usrKey -ErrorAction SilentlyContinue | ForEach-Object {
                        try {
                            $p2 = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                            if ($p2) {
                                $p2.PSObject.Properties | Where-Object { $_.Value -is [string] } | ForEach-Object { $found += [string]$_.Value }
                            }
                        } catch {}
                    }
                }
            } catch {}
        }
    } catch {}
    return @($found | Where-Object { Test-IsPlausibleWindowsPath $_ } | Select-Object -Unique)
}

# Detecta caminhos do iCloud Drive existentes na máquina: candidatos padrão em
# %USERPROFILE%, o que o registro apontar (pasta movida) e varredura por nome nas
# raízes informadas (mesmo padrão de Get-CaminhosOneDrive). Só entram candidatos que
# realmente existem no disco (Test-Path) — sem iCloud instalado, devolve lista vazia.
function Get-CaminhosICloud {
    param([string[]]$Roots = @())
    $cands = @()

    foreach ($name in (Get-ICloudFolderNames)) {
        if ($env:USERPROFILE) { $cands += (Join-Path $env:USERPROFILE $name) }
    }

    $cands += (Get-ICloudPathsFromRegistry)

    $searchRoots = @($env:USERPROFILE) + $Roots
    foreach ($r in ($searchRoots | Where-Object { $_ } | Select-Object -Unique)) {
        Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'iCloud*Drive*' } |
            ForEach-Object { $cands += $_.FullName }
    }

    return @($cands | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

# (PURA) Classifica um caminho quanto ao provedor de nuvem e se a liberação por
# atributo (attrib +U) se aplica. Recebe as raízes conhecidas (injetáveis = testável).
function Resolve-CloudInfo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$StreamRoots   = @(),
        [string[]]$MirrorRoots   = @(),
        [string[]]$OneDriveRoots = @(),
        [string[]]$ICloudRoots   = @()
    )
    $norm = ($Path.TrimEnd('\') + '\').ToUpperInvariant()
    $under = {
        param($root)
        if (-not $root) { return $false }
        return $norm.StartsWith((($root.TrimEnd('\')) + '\').ToUpperInvariant())
    }

    foreach ($r in $StreamRoots) {
        if (& $under $r) {
            return [PSCustomObject]@{
                provider = 'googledrive'
                mode     = 'stream'
                freeable = $false
                note     = 'Google Drive (Stream): arquivos vivem num volume virtual FAT32 e mostram o tamanho lógico; o espaço real fica no content_cache. Liberar por atributo não se aplica — use o app do Google Drive (somente-nuvem) ou limpe o cache.'
            }
        }
    }
    foreach ($r in $MirrorRoots) {
        if (& $under $r) {
            return [PSCustomObject]@{
                provider = 'googledrive'
                mode     = 'mirror'
                freeable = $false
                note     = 'Google Drive (Espelho/Mirror): arquivos são cópias locais reais. Para recuperar espaço, delete (reflete na nuvem) ou troque a pasta para Stream nas configurações do Google Drive.'
            }
        }
    }
    foreach ($r in $OneDriveRoots) {
        if (& $under $r) {
            return [PSCustomObject]@{ provider = 'onedrive'; mode = 'filesondemand'; freeable = $true; note = '' }
        }
    }
    foreach ($r in $ICloudRoots) {
        if (& $under $r) {
            # iCloud for Windows usa a MESMA Cloud Files API do OneDrive (placeholders NTFS
            # + atributo Offline): mesmo motor de liberação por atributo (+U -P).
            return [PSCustomObject]@{ provider = 'icloud'; mode = 'filesondemand'; freeable = $true; note = '' }
        }
    }
    return [PSCustomObject]@{ provider = 'none'; mode = ''; freeable = $true; note = '' }
}

# Wrapper de IO: detecta as raízes ao vivo e classifica o caminho informado.
function Get-PathCloudInfo {
    param([Parameter(Mandatory)][string]$Path)
    $driveRoots  = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Root)
    $gd          = Get-CaminhosGoogleDrive -Roots $driveRoots
    $streamRoots = @((Get-GoogleDriveStreamVolumes).root) + @($gd | Where-Object { $_.mode -eq 'stream' } | ForEach-Object { $_.path })
    $mirrorRoots = @($gd | Where-Object { $_.mode -eq 'mirror' } | ForEach-Object { $_.path })
    $odRoots     = @(Get-CaminhosOneDrive -Roots $driveRoots)
    $icRoots     = @(Get-CaminhosICloud -Roots $driveRoots)
    return Resolve-CloudInfo -Path $Path -StreamRoots $streamRoots -MirrorRoots $mirrorRoots -OneDriveRoots $odRoots -ICloudRoots $icRoots
}

# Varre todos os discos do sistema de arquivos e retorna métricas + OneDrive detectado.
function Get-DiscosDoSistema {
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
              Where-Object { $_.Free -ne $null -or $_.Used -ne $null }

    $allOneDrive = Get-CaminhosOneDrive -Roots @($drives | ForEach-Object { $_.Root })
    $allGoogle   = Get-CaminhosGoogleDrive -Roots @($drives | ForEach-Object { $_.Root })
    $allICloud   = Get-CaminhosICloud -Roots @($drives | ForEach-Object { $_.Root })
    $gdriveCache = Get-GoogleDriveCacheInfo

    $disks = foreach ($d in $drives) {
        $free  = [int64]($d.Free)
        $used  = [int64]($d.Used)
        $total = $free + $used
        if ($total -le 0) { continue }

        # Volume label via WMI/CIM (best-effort)
        $label = $null
        try {
            $vol = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f ($d.Name + ':')) -ErrorAction SilentlyContinue
            if ($vol) { $label = $vol.VolumeName }
        } catch {}

        # Caminhos OneDrive, Google Drive e iCloud Drive que vivem neste drive
        $odHere = @($allOneDrive | Where-Object { $_ -like ($d.Name + ':*') })
        $gdHere = @($allGoogle   | Where-Object { $_.path -like ($d.Name + ':*') })
        $icHere = @($allICloud   | Where-Object { $_ -like ($d.Name + ':*') })

        [PSCustomObject]@{
            letter           = $d.Name + ':'
            root             = $d.Root
            label            = if ($label) { $label } else { '' }
            totalBytes       = $total
            usedBytes        = $used
            freeBytes        = $free
            usedFormatted    = Format-Tamanho $used
            freeFormatted    = Format-Tamanho $free
            totalFormatted   = Format-Tamanho $total
            usedPercent      = [math]::Round(($used / $total) * 100, 1)
            oneDrivePaths    = $odHere
            hasOneDrive      = ($odHere.Count -gt 0)
            googleDrivePaths = $gdHere
            hasGoogleDrive   = ($gdHere.Count -gt 0)
            icloudPaths      = $icHere
            hasICloud        = ($icHere.Count -gt 0)
        }
    }

    return [PSCustomObject]@{
        disks         = @($disks)
        oneDrivePaths = $allOneDrive
        icloudPaths   = $allICloud
        googleDrive   = [PSCustomObject]@{
            installed      = $gdriveCache.installed
            cacheBytes     = $gdriveCache.totalBytes
            cacheFormatted = $gdriveCache.totalFormatted
            accounts       = $gdriveCache.accounts
            paths          = $allGoogle
        }
    }
}

# ================================================================
# SERVIDOR HTTP (HttpListener)
# ================================================================

function Send-Json {
    param($Response, $Object, [int]$Status = 200)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $Status
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Send-Html {
    param($Response, [string]$Html)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Response.StatusCode = 200
    $Response.ContentType = 'text/html; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

# Prepara a resposta para Server-Sent Events (stream chunked, sem buffer).
function Start-Sse {
    param($Response)
    $Response.StatusCode = 200
    $Response.ContentType = 'text/event-stream; charset=utf-8'
    $Response.Headers.Add('Cache-Control', 'no-cache')
    $Response.Headers.Add('X-Accel-Buffering', 'no')
    $Response.SendChunked = $true
    $Response.KeepAlive = $true
}

# Envia um evento SSE (data: <json>\n\n). Retorna $false se o cliente desconectou.
function Send-SseData {
    param($Response, $Object)
    try {
        $json = $Object | ConvertTo-Json -Depth 6 -Compress
        $payload = "data: $json`n`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Response.OutputStream.Flush()
        return $true
    } catch {
        return $false  # conexão fechada pelo cliente (cancelamento)
    }
}

function Read-Body {
    param($Request)
    if (-not $Request.HasEntityBody) { return $null }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $text = $reader.ReadToEnd()
    $reader.Close()
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
}

function Write-Log {
    param([string]$Method, [string]$Path, [int]$Status)
    $ts = (Get-Date).ToString('HH:mm:ss')
    $color = if ($Status -ge 500) { 'Red' } elseif ($Status -ge 400) { 'Yellow' } else { 'Green' }
    Write-Host ("[{0}] {1,-5} {2} -> {3}" -f $ts, $Method, $Path, $Status) -ForegroundColor $color
}

function Start-CloudCleaner {
    # Transcript: captura TAMBÉM o que Write-Host escreve (Write-Host vai para o host,
    # não para o stream de saída — redirecionar ">" o processo NÃO captura Write-Host;
    # Start-Transcript captura). É o log "narrativo" completo de uma execução, ao lado
    # do CloudCleaner-error.log (só falhas). Best-effort: se não conseguir (ex.: outra
    # transcrição já em andamento, diretório sem permissão), segue sem travar o app.
    $script:TranscriptStarted = $false
    if ($script:LogPath) {
        try { Start-Transcript -Path $script:LogPath -Append -ErrorAction Stop | Out-Null; $script:TranscriptStarted = $true } catch {}
    }

    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add($script:Prefix)

        try {
            $listener.Start()
        } catch {
            Write-Host "ERRO ao iniciar o servidor em $($script:Prefix)" -ForegroundColor Red
            Write-Host "Detalhe: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Dica: a porta $($script:Port) pode estar em uso. Feche o outro programa e tente novamente." -ForegroundColor Yellow
            # Sem isso, essa falha era 100% muda pro usuário: roda oculto, sem janela
            # nenhuma pra mostrar o Write-Host acima — "instalei e não abriu nada".
            Show-CloudCleanerFatalError -Context 'HttpListener.Start' -ErrorRecord $_
            return
        }

    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "  CloudCleaner v1.3.1" -ForegroundColor Cyan
    Write-Host "  Analisador e Otimizador de Pastas OneDrive, iCloud Drive e Google Drive" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "Servidor rodando em: $($script:Prefix)" -ForegroundColor Green
    Write-Host "Abrindo o navegador..." -ForegroundColor Green
    Write-Host "Feche a aba do navegador para encerrar (ou Ctrl+C nesta janela)." -ForegroundColor Yellow
    Write-Host "-------------------------------------------------"

    # Abre o navegador automaticamente (a menos que -NoBrowser)
    if (-not $NoBrowser) {
        try { Start-Process $script:Prefix } catch { Write-Host "Abra manualmente: $($script:Prefix)" -ForegroundColor Yellow }
    } else {
        Write-Host "Modo -NoBrowser: abra manualmente em $($script:Prefix)" -ForegroundColor Yellow
    }

    # Encerramento automático (task #2760): $script:LastSignalUtc começa em "agora" (dá
    # tempo do navegador abrir e mandar o 1º heartbeat antes da guarda de silêncio valer).
    # /api/heartbeat atualiza o sinal; /api/shutdown (chamado no fechamento da aba) pede
    # a saída imediata via $script:ShutdownRequested.
    $script:LastSignalUtc      = [DateTime]::UtcNow
    $script:ShutdownRequested  = $false
    $watchdogPollMs            = 1000

    try {
        $pendingIar = $null
        while ($listener.IsListening) {
            # Aceita a próxima conexão de forma assíncrona e espera em janelas curtas
            # (em vez de bloquear para sempre em GetContext()) para poder checar, a cada
            # janela sem requisição nenhuma, se o navegador sumiu (guarda de silêncio).
            if (-not $pendingIar) { $pendingIar = $listener.BeginGetContext($null, $null) }
            $signaled = $pendingIar.AsyncWaitHandle.WaitOne($watchdogPollMs)

            if (-not $signaled) {
                if (Test-ShouldAutoShutdown -LastSignalUtc $script:LastSignalUtc -NowUtc ([DateTime]::UtcNow) -TimeoutSeconds $script:HeartbeatTimeoutSeconds) {
                    Write-Host ("Sem sinal do navegador há {0}s — encerrando sozinho." -f $script:HeartbeatTimeoutSeconds) -ForegroundColor Yellow
                    break
                }
                continue
            }

            $context  = $listener.EndGetContext($pendingIar)
            $pendingIar = $null
            $request  = $context.Request
            $response = $context.Response
            $path     = $request.Url.AbsolutePath
            $method   = $request.HttpMethod
            $status   = 200

            try {
                switch -Regex ($path) {

                    '^/$' {
                        $indexPath = Join-Path $script:Root 'index.html'
                        if (Test-Path -LiteralPath $indexPath) {
                            $html = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8
                            Send-Html -Response $response -Html $html
                        } else {
                            $status = 404
                            Send-Json -Response $response -Object @{ error = 'index.html não encontrado.' } -Status 404
                        }
                        break
                    }

                    '^/api/suggestions$' {
                        $info = Get-DiscosDoSistema
                        $gd = $info.googleDrive
                        if ($gd) { $gd | Add-Member -NotePropertyName cleanupConfirmPhrase -NotePropertyValue $script:GDriveCleanupConfirmPhrase -Force }
                        Send-Json -Response $response -Object @{ disks = $info.disks; paths = $info.oneDrivePaths; icloudPaths = $info.icloudPaths; googleDrive = $gd }
                        break
                    }

                    '^/api/disk-free$' {
                        $p = $request.QueryString['path']
                        if (-not $p) { $status = 400; Send-Json -Response $response -Object @{ error = 'parâmetro path ausente' } -Status 400; break }
                        $disk = Get-DiscoLivre -Caminho $p
                        if ($null -eq $disk) { $status = 400; Send-Json -Response $response -Object @{ error = 'caminho inválido' } -Status 400; break }
                        Send-Json -Response $response -Object $disk
                        break
                    }

                    '^/api/scan$' {
                        $p = $request.QueryString['path']
                        if (-not $p) { $status = 400; Send-Json -Response $response -Object @{ error = 'parâmetro path ausente' } -Status 400; break }
                        try {
                            $result = Get-AnaliseDePasta -Caminho $p
                            Send-Json -Response $response -Object $result
                        } catch {
                            $status = 400
                            Send-Json -Response $response -Object @{ error = $_.Exception.Message } -Status 400
                        }
                        break
                    }

                    '^/api/free-space$' {
                        # Stream de progresso via SSE (consumido por EventSource → GET).
                        $p = $request.QueryString['path']
                        if (-not $p) { $status = 400; Send-Json -Response $response -Object @{ error = 'parâmetro path ausente' } -Status 400; break }
                        Start-Sse -Response $response
                        try { Invoke-LiberarEspacoStream -Response $response -Caminho $p }
                        catch { Send-SseData -Response $response -Object @{ phase = 'error'; message = $_.Exception.Message } | Out-Null }
                        finally { try { $response.OutputStream.Close() } catch {} }
                        break
                    }

                    '^/api/delete$' {
                        # Stream de progresso via SSE (consumido por EventSource → GET).
                        $p = $request.QueryString['path']
                        if (-not $p) { $status = 400; Send-Json -Response $response -Object @{ error = 'parâmetro path ausente' } -Status 400; break }
                        Start-Sse -Response $response
                        try { Invoke-DeletarStream -Response $response -Caminho $p }
                        catch { Send-SseData -Response $response -Object @{ phase = 'error'; message = $_.Exception.Message } | Out-Null }
                        finally { try { $response.OutputStream.Close() } catch {} }
                        break
                    }

                    '^/api/gdrive-cache-cleanup$' {
                        # Limpeza GUARDADA do content_cache do Google Drive Stream (task #327).
                        # POST { account: "<pasta da conta em %LOCALAPPDATA%\Google\DriveFS>", confirm: "<frase>" }
                        if ($method -ne 'POST') {
                            $status = 405
                            Send-Json -Response $response -Object @{ error = 'use POST' } -Status 405
                            break
                        }
                        $body = Read-Body -Request $request
                        $account = if ($body -and $body.account) { [string]$body.account } else { $null }
                        $confirm = if ($body -and $null -ne $body.confirm) { [string]$body.confirm } else { '' }
                        if (-not $account) {
                            $status = 400
                            Send-Json -Response $response -Object @{ error = 'parâmetro "account" ausente' } -Status 400
                            break
                        }

                        $appData = Get-GoogleDriveAppData
                        if (-not $appData -or -not (Test-Path -LiteralPath $appData)) {
                            $status = 400
                            Send-Json -Response $response -Object @{ error = 'Google Drive não detectado nesta máquina.' } -Status 400
                            break
                        }
                        $cacheDir  = Join-Path (Join-Path $appData $account) 'content_cache'
                        $mountRoot = (@(Get-GoogleDriveStreamVolumes) | Select-Object -First 1).root

                        $result = Invoke-LimpezaGuardadaGoogleDriveCache -CacheDir $cacheDir -Confirm $confirm -MountRoot $mountRoot
                        if ($result.success) {
                            Send-Json -Response $response -Object $result
                        } else {
                            $status = 409
                            Send-Json -Response $response -Object $result -Status 409
                        }
                        break
                    }

                    '^/api/heartbeat$' {
                        # Chamado periodicamente pelo navegador (aba aberta) — task #2760.
                        # Alimenta a guarda de silêncio (Test-ShouldAutoShutdown); nenhuma
                        # ação além de marcar "ainda tem alguém ouvindo".
                        $script:LastSignalUtc = [DateTime]::UtcNow
                        Send-Json -Response $response -Object @{ ok = $true }
                        break
                    }

                    '^/api/shutdown$' {
                        # Chamado no fechamento da aba (navigator.sendBeacon, evento 'pagehide')
                        # — sinal EXPLÍCITO, mais rápido que esperar a guarda de silêncio.
                        Send-Json -Response $response -Object @{ ok = $true }
                        $script:ShutdownRequested = $true
                        break
                    }

                    '^/api/open-folder$' {
                        # Extra sugerido pelo Nelson (task #2760): abre o Explorador de
                        # Arquivos já na pasta selecionada. POST { path: "<pasta>" }.
                        if ($method -ne 'POST') {
                            $status = 405
                            Send-Json -Response $response -Object @{ error = 'use POST' } -Status 405
                            break
                        }
                        $body = Read-Body -Request $request
                        $p = if ($body -and $body.path) { [string]$body.path } else { $null }
                        if (-not $p) {
                            $status = 400
                            Send-Json -Response $response -Object @{ error = 'parâmetro "path" ausente' } -Status 400
                            break
                        }
                        try {
                            Invoke-AbrirPastaNoExplorer -Caminho $p
                            Send-Json -Response $response -Object @{ ok = $true }
                        } catch {
                            $status = 400
                            Send-Json -Response $response -Object @{ error = $_.Exception.Message } -Status 400
                        }
                        break
                    }

                    default {
                        $status = 404
                        Send-Json -Response $response -Object @{ error = 'rota não encontrada' } -Status 404
                    }
                }
            } catch {
                $status = 500
                try { Send-Json -Response $response -Object @{ error = $_.Exception.Message } -Status 500 } catch {}
            }

            Write-Log -Method $method -Path $path -Status $status

            # Sinal explícito de fechamento (/api/shutdown) já respondeu ao navegador;
            # agora sai do loop e deixa o bloco finally encerrar o listener.
            if ($script:ShutdownRequested) { break }
        }
    } finally {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
        Write-Host "`nServidor encerrado. Até a próxima!" -ForegroundColor Cyan
    }
    } catch {
        # Qualquer erro não previsto nos blocos acima (ex.: exceção ao criar o
        # HttpListener antes mesmo do Start, falha dentro do loop de requisições que
        # escapou dos try/catch internos) — antes disso o processo simplesmente
        # sumia sem deixar rastro nenhum pro usuário.
        Show-CloudCleanerFatalError -Context 'Start-CloudCleaner' -ErrorRecord $_
    } finally {
        if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
    }
}

# ===== INÍCIO =====
# Quando carregado com -NoServe (dot-source nos testes), não inicia o servidor.
if (-not $NoServe) {
    try {
        Start-CloudCleaner
    } catch {
        # Rede de segurança final: mesmo algo lançado FORA do try interno de
        # Start-CloudCleaner (ex.: erro ao definir $script:Prefix) fica visível,
        # em vez de o processo simplesmente encerrar sem sinal nenhum.
        Show-CloudCleanerFatalError -Context 'INÍCIO' -ErrorRecord $_
    }
}
