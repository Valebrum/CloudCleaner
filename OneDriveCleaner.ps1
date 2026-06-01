# OneDriveCleaner - Analisador e Otimizador de Pastas OneDrive
# Idealizador: Nelson Brum
# Desenvolvedor: Claude + Nelson
# Versão: 0.8.3
# Data: 2026-05-31
#
# O que faz:
#   Analisa pastas (OneDrive-friendly), comparando tamanho LÓGICO (total na nuvem)
#   com tamanho LOCAL (ocupado no disco, ignorando itens só-na-nuvem). Permite
#   liberar espaço local (tornar somente-nuvem via attrib +U -P) ou deletar arquivos.
#
# Arquitetura: backend PowerShell (HttpListener em localhost:8080) + interface HTML.
#
# Execução sugerida:
#   powershell -ExecutionPolicy Bypass -File .\OneDriveCleaner.ps1
#
# Observação: roda em Windows PowerShell 5.x ou PowerShell 7+ (Windows).
#             Requer permissão para escutar em http://localhost:8080.

# ================================================================
# CONFIGURAÇÃO INICIAL
# ================================================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$script:Port    = 8080
$script:Prefix  = "http://localhost:$($script:Port)/"
$script:Root    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

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

# Libera espaço local (OneDrive): torna arquivos somente-nuvem (attrib +U -P), sem excluir da nuvem.
function Invoke-LiberarEspaco {
    param([Parameter(Mandatory)][string]$Caminho)

    if (-not (Test-Path -LiteralPath $Caminho)) { throw "Caminho inválido: $Caminho" }

    $localFiles = Get-ChildItem -LiteralPath $Caminho -Recurse -File -Force -ErrorAction SilentlyContinue |
                  Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Offline) }

    $qtd = ($localFiles | Measure-Object).Count
    $bytes = ($localFiles | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }

    if ($qtd -eq 0) {
        return [PSCustomObject]@{ ok = $true; freedFiles = 0; freedBytes = 0; message = "Nenhum arquivo local para liberar." }
    }

    & attrib.exe +U -P "$Caminho\*" /s /d 2>$null

    return [PSCustomObject]@{
        ok             = $true
        freedFiles     = $qtd
        freedBytes     = [int64]$bytes
        freedFormatted = Format-Tamanho $bytes
        message        = ("Convertidos para somente-nuvem: {0} arquivo(s). Estimativa liberada: {1}." -f (Format-Numero $qtd), (Format-Tamanho $bytes))
    }
}

# Deleta definitivamente os arquivos de uma pasta (reflete na nuvem se sincronizado).
function Invoke-Deletar {
    param([Parameter(Mandatory)][string]$Caminho)

    if (-not (Test-Path -LiteralPath $Caminho)) { throw "Caminho inválido: $Caminho" }

    $files = Get-ChildItem -LiteralPath $Caminho -Recurse -File -Force -ErrorAction SilentlyContinue
    $count = ($files | Measure-Object).Count
    if ($count -eq 0) {
        return [PSCustomObject]@{ ok = $true; deletedFiles = 0; message = "Nada a excluir." }
    }

    $files | Remove-Item -Force -ErrorAction Stop

    return [PSCustomObject]@{
        ok           = $true
        deletedFiles = $count
        message      = ("Excluídos {0} arquivo(s) em: {1}" -f (Format-Numero $count), $Caminho)
    }
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

# Varre todos os discos do sistema de arquivos e retorna métricas + OneDrive detectado.
function Get-DiscosDoSistema {
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
              Where-Object { $_.Free -ne $null -or $_.Used -ne $null }

    $allOneDrive = Get-CaminhosOneDrive -Roots @($drives | ForEach-Object { $_.Root })

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

        # Caminhos OneDrive que vivem neste drive
        $odHere = @($allOneDrive | Where-Object { $_ -like ($d.Name + ':*') })

        [PSCustomObject]@{
            letter        = $d.Name + ':'
            root          = $d.Root
            label         = if ($label) { $label } else { '' }
            totalBytes    = $total
            usedBytes     = $used
            freeBytes     = $free
            usedFormatted = Format-Tamanho $used
            freeFormatted = Format-Tamanho $free
            totalFormatted= Format-Tamanho $total
            usedPercent   = [math]::Round(($used / $total) * 100, 1)
            oneDrivePaths = $odHere
            hasOneDrive   = ($odHere.Count -gt 0)
        }
    }

    return [PSCustomObject]@{
        disks         = @($disks)
        oneDrivePaths = $allOneDrive
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

function Start-OneDriveCleaner {
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
    Write-Host "  OneDriveCleaner v0.8.3" -ForegroundColor Cyan
    Write-Host "  Analisador e Otimizador de Pastas OneDrive" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "Servidor rodando em: $($script:Prefix)" -ForegroundColor Green
    Write-Host "Abrindo o navegador..." -ForegroundColor Green
    Write-Host "Pressione Ctrl+C nesta janela para encerrar." -ForegroundColor Yellow
    Write-Host "-------------------------------------------------"

    # Abre o navegador automaticamente
    try { Start-Process $script:Prefix } catch { Write-Host "Abra manualmente: $($script:Prefix)" -ForegroundColor Yellow }

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
                        Send-Json -Response $response -Object @{ disks = $info.disks; paths = $info.oneDrivePaths }
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
                        if ($method -ne 'POST') { $status = 405; Send-Json -Response $response -Object @{ error = 'use POST' } -Status 405; break }
                        $body = Read-Body -Request $request
                        if (-not $body -or -not $body.path) { $status = 400; Send-Json -Response $response -Object @{ error = 'body {path} ausente' } -Status 400; break }
                        try {
                            $result = Invoke-LiberarEspaco -Caminho $body.path
                            Send-Json -Response $response -Object $result
                        } catch {
                            $status = 500
                            Send-Json -Response $response -Object @{ ok = $false; error = $_.Exception.Message } -Status 500
                        }
                        break
                    }

                    '^/api/delete$' {
                        if ($method -ne 'POST') { $status = 405; Send-Json -Response $response -Object @{ error = 'use POST' } -Status 405; break }
                        $body = Read-Body -Request $request
                        if (-not $body -or -not $body.path) { $status = 400; Send-Json -Response $response -Object @{ error = 'body {path} ausente' } -Status 400; break }
                        try {
                            $result = Invoke-Deletar -Caminho $body.path
                            Send-Json -Response $response -Object $result
                        } catch {
                            $status = 500
                            Send-Json -Response $response -Object @{ ok = $false; error = $_.Exception.Message } -Status 500
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
        }
    } finally {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
        Write-Host "`nServidor encerrado. Até a próxima!" -ForegroundColor Cyan
    }
}

# ===== INÍCIO =====
Start-OneDriveCleaner
