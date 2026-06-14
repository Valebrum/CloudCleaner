# CloudCleaner - Analisador e Otimizador de Pastas OneDrive e Google Drive
# Idealizador: Nelson Brum
# Desenvolvedor: Claude + Nelson
# Versão: 1.0.1
# Data: 2026-06-13
#
# O que faz:
#   Analisa pastas (OneDrive-friendly), comparando tamanho LÓGICO (total na nuvem)
#   com tamanho LOCAL (ocupado no disco, ignorando itens só-na-nuvem). Permite
#   liberar espaço local (tornar somente-nuvem via attrib +U -P) ou deletar arquivos.
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
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$script:Port    = 8080
$script:Prefix  = "http://localhost:$($script:Port)/"
$script:Root    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# API nativa Win32 para definir atributos de nuvem (UNPINNED/PINNED), que o enum
# [System.IO.FileAttributes] do .NET rejeita. É exatamente o que o attrib.exe faz.
if (-not ('Win32.NativeFs' -as [type])) {
    Add-Type -Namespace Win32 -Name NativeFs -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool SetFileAttributesW(string lpFileName, uint dwFileAttributes);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint GetFileAttributesW(string lpFileName);
'@
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
    $cands += (Join-Path $env:USERPROFILE 'OneDrive')

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
    if (Test-Path -LiteralPath $base) {
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
        installed      = (Test-Path -LiteralPath $base)
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

# (PURA) Classifica um caminho quanto ao provedor de nuvem e se a liberação por
# atributo (attrib +U) se aplica. Recebe as raízes conhecidas (injetáveis = testável).
function Resolve-CloudInfo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$StreamRoots   = @(),
        [string[]]$MirrorRoots   = @(),
        [string[]]$OneDriveRoots = @()
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
    return Resolve-CloudInfo -Path $Path -StreamRoots $streamRoots -MirrorRoots $mirrorRoots -OneDriveRoots $odRoots
}

# Varre todos os discos do sistema de arquivos e retorna métricas + OneDrive detectado.
function Get-DiscosDoSistema {
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
              Where-Object { $_.Free -ne $null -or $_.Used -ne $null }

    $allOneDrive = Get-CaminhosOneDrive -Roots @($drives | ForEach-Object { $_.Root })
    $allGoogle   = Get-CaminhosGoogleDrive -Roots @($drives | ForEach-Object { $_.Root })
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

        # Caminhos OneDrive e Google Drive que vivem neste drive
        $odHere = @($allOneDrive | Where-Object { $_ -like ($d.Name + ':*') })
        $gdHere = @($allGoogle   | Where-Object { $_.path -like ($d.Name + ':*') })

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
        }
    }

    return [PSCustomObject]@{
        disks         = @($disks)
        oneDrivePaths = $allOneDrive
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
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($script:Prefix)

    try {
        $listener.Start()
    } catch {
        Write-Host "ERRO ao iniciar o servidor em $($script:Prefix)" -ForegroundColor Red
        Write-Host "Detalhe: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Dica: a porta $($script:Port) pode estar em uso. Feche o outro programa e tente novamente." -ForegroundColor Yellow
        return
    }

    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "  CloudCleaner v1.0.1" -ForegroundColor Cyan
    Write-Host "  Analisador e Otimizador de Pastas OneDrive e Google Drive" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "Servidor rodando em: $($script:Prefix)" -ForegroundColor Green
    Write-Host "Abrindo o navegador..." -ForegroundColor Green
    Write-Host "Pressione Ctrl+C nesta janela para encerrar." -ForegroundColor Yellow
    Write-Host "-------------------------------------------------"

    # Abre o navegador automaticamente (a menos que -NoBrowser)
    if (-not $NoBrowser) {
        try { Start-Process $script:Prefix } catch { Write-Host "Abra manualmente: $($script:Prefix)" -ForegroundColor Yellow }
    } else {
        Write-Host "Modo -NoBrowser: abra manualmente em $($script:Prefix)" -ForegroundColor Yellow
    }

    try {
        while ($listener.IsListening) {
            $context  = $listener.GetContext()
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
                        Send-Json -Response $response -Object @{ disks = $info.disks; paths = $info.oneDrivePaths; googleDrive = $info.googleDrive }
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
        }
    } finally {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
        Write-Host "`nServidor encerrado. Até a próxima!" -ForegroundColor Cyan
    }
}

# ===== INÍCIO =====
# Quando carregado com -NoServe (dot-source nos testes), não inicia o servidor.
if (-not $NoServe) {
    Start-CloudCleaner
}
