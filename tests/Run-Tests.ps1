# Run-Tests.ps1 — testes do CloudCleaner (sem dependência de Pester).
# Faz dot-source do script com -NoServe (carrega só as funções) e roda asserts.
#
# Uso:  powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
# Sai com código 1 se qualquer teste falhar (bom para CI).

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\CloudCleaner.ps1') -NoServe

$script:Pass = 0
$script:Fail = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -eq $Actual) {
        $script:Pass++; Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green
    } else {
        $script:Fail++; Write-Host ("  [FAIL] {0}`n         esperado: {1}`n         obtido:   {2}" -f $Name, $Expected, $Actual) -ForegroundColor Red
    }
}
function Assert-True  { param($Cond, [string]$Name) Assert-Equal $true  ([bool]$Cond) $Name }
function Assert-False { param($Cond, [string]$Name) Assert-Equal $false ([bool]$Cond) $Name }

Write-Host "=== Get-UnpinnedAttributeValue (math pura +U/-P) ===" -ForegroundColor Cyan
# Normal (0x80) -> liga UNPINNED(0x100000), preserva 0x80, sem PINNED.
Assert-Equal ([uint32]0x100080) (Get-UnpinnedAttributeValue -Current ([uint64]0x80))    'Normal vira UNPINNED preservando 0x80'
# PINNED (0x80000) -> deve DESLIGAR PINNED e ligar UNPINNED.
Assert-Equal ([uint32]0x100000) (Get-UnpinnedAttributeValue -Current ([uint64]0x80000)) 'PINNED é removido e UNPINNED ligado'
# Archive (0x20) -> preserva 0x20.
Assert-Equal ([uint32]0x100020) (Get-UnpinnedAttributeValue -Current ([uint64]0x20))    'Archive preservado + UNPINNED'
# Já UNPINNED -> idempotente.
Assert-Equal ([uint32]0x100000) (Get-UnpinnedAttributeValue -Current ([uint64]0x100000)) 'UNPINNED é idempotente'

Write-Host "=== Test-IsGoogleDriveStreamVolume (assinatura de volume) ===" -ForegroundColor Cyan
Assert-True  (Test-IsGoogleDriveStreamVolume -Label 'Google Drive'  -FileSystem 'FAT32') 'rótulo Google Drive + FAT32 = Stream'
Assert-True  (Test-IsGoogleDriveStreamVolume -Label 'google drive'  -FileSystem 'FAT32') 'rótulo é case-insensitive'
Assert-True  (Test-IsGoogleDriveStreamVolume -Label 'Google Drive ' -FileSystem '')      'rótulo com espaço (trim)'
Assert-False (Test-IsGoogleDriveStreamVolume -Label 'OneDrive'      -FileSystem 'NTFS')  'OneDrive não é Stream'
Assert-False (Test-IsGoogleDriveStreamVolume -Label 'Games - HD'    -FileSystem 'NTFS')  'disco comum não é Stream'
Assert-False (Test-IsGoogleDriveStreamVolume -Label ''              -FileSystem 'FAT32') 'sem rótulo não é Stream'

Write-Host "=== Resolve-CloudInfo (classificação de caminho) ===" -ForegroundColor Cyan
$stream = @('E:\')
$mirror = @('C:\Users\nelson\Meu Drive')
$od     = @('D:\OneDrive - Grupo Valebrum')

$r1 = Resolve-CloudInfo -Path 'E:\Meu Drive\Fotos' -StreamRoots $stream -MirrorRoots $mirror -OneDriveRoots $od
Assert-Equal 'googledrive' $r1.provider 'caminho em Stream -> googledrive'
Assert-Equal 'stream'      $r1.mode     'caminho em Stream -> mode stream'
Assert-False $r1.freeable                'Stream NÃO é liberável por atributo'

$r2 = Resolve-CloudInfo -Path 'C:\Users\nelson\Meu Drive\Docs' -StreamRoots $stream -MirrorRoots $mirror -OneDriveRoots $od
Assert-Equal 'googledrive' $r2.provider 'caminho em Mirror -> googledrive'
Assert-Equal 'mirror'      $r2.mode     'caminho em Mirror -> mode mirror'
Assert-False $r2.freeable                'Mirror NÃO é liberável por atributo'

$r3 = Resolve-CloudInfo -Path 'D:\OneDrive - Grupo Valebrum\x' -StreamRoots $stream -MirrorRoots $mirror -OneDriveRoots $od
Assert-Equal 'onedrive' $r3.provider 'caminho em OneDrive -> onedrive'
Assert-True  $r3.freeable             'OneDrive É liberável por atributo'

$r4 = Resolve-CloudInfo -Path 'C:\Temp\qualquer' -StreamRoots $stream -MirrorRoots $mirror -OneDriveRoots $od
Assert-Equal 'none' $r4.provider 'caminho fora de nuvem -> none'
Assert-True  $r4.freeable         'caminho comum é liberável (sem bloqueio)'

# Borda: prefixo não pode casar parcialmente (trailing backslash protege).
$r5 = Resolve-CloudInfo -Path 'C:\Users\nelson\Meu DriveX\y' -StreamRoots @() -MirrorRoots $mirror -OneDriveRoots @()
Assert-Equal 'none' $r5.provider 'Meu DriveX NÃO casa com Meu Drive (prefixo exato)'

Write-Host "=== Resolve-CloudInfo — iCloud Drive (reusa o motor do OneDrive) ===" -ForegroundColor Cyan
$icloud = @('D:\iCloud Drive')

$r6 = Resolve-CloudInfo -Path 'D:\iCloud Drive\Documentos' -StreamRoots $stream -MirrorRoots $mirror -OneDriveRoots $od -ICloudRoots $icloud
Assert-Equal 'icloud' $r6.provider 'caminho em iCloud Drive -> icloud'
Assert-True  $r6.freeable            'iCloud Drive É liberável por atributo (mesmo motor do OneDrive)'

$r7 = Resolve-CloudInfo -Path 'D:\iCloud Drive' -StreamRoots @() -MirrorRoots @() -OneDriveRoots @() -ICloudRoots $icloud
Assert-Equal 'icloud' $r7.provider 'a própria raiz do iCloud Drive também classifica como icloud'

# Borda: prefixo não pode casar parcialmente (mesma proteção do OneDrive/Google Drive).
$r8 = Resolve-CloudInfo -Path 'C:\Users\nelson\iCloud DriveX\y' -StreamRoots @() -MirrorRoots @() -OneDriveRoots @() -ICloudRoots @('C:\Users\nelson\iCloud Drive')
Assert-Equal 'none' $r8.provider 'iCloud DriveX NÃO casa com iCloud Drive (prefixo exato)'

# Sem iCloud instalado (raízes vazias) -> não aparece nada, sem erro.
$r9 = Resolve-CloudInfo -Path 'C:\Temp\qualquer' -StreamRoots @() -MirrorRoots @() -OneDriveRoots @() -ICloudRoots @()
Assert-Equal 'none' $r9.provider 'sem iCloud instalado (ICloudRoots vazio) -> none, sem erro'

Write-Host "=== Get-ICloudFolderNames (nomes de pasta candidatos, sem I/O) ===" -ForegroundColor Cyan
$icNames = Get-ICloudFolderNames
Assert-True ($icNames.Count -ge 2)                    'ao menos dois nomes candidatos (app da Store x MSI clássico)'
Assert-True (('iCloud Drive')  -in $icNames)           'inclui "iCloud Drive" (com espaço, app da Microsoft Store / iCloud 14+)'
Assert-True (('iCloudDrive')   -in $icNames)           'inclui "iCloudDrive" (sem espaço, instalador MSI clássico)'

Write-Host "=== Test-IsPlausibleWindowsPath (filtro de valor de registro, sem I/O) ===" -ForegroundColor Cyan
Assert-True  (Test-IsPlausibleWindowsPath 'D:\iCloud Drive')        'caminho absoluto Windows válido (D:\...)'
Assert-True  (Test-IsPlausibleWindowsPath 'C:\Users\nelson\iCloudDrive') 'caminho absoluto Windows válido (C:\...)'
Assert-False (Test-IsPlausibleWindowsPath '')                        'string vazia não é caminho'
Assert-False (Test-IsPlausibleWindowsPath $null)                     'null não é caminho'
Assert-False (Test-IsPlausibleWindowsPath 'iCloud Drive')            'caminho relativo (sem letra de unidade) não é válido'
Assert-False (Test-IsPlausibleWindowsPath '/home/nelson/iCloud')     'caminho estilo Unix não é válido'

Write-Host "=== Detecção ao vivo (informativo; não falha o suite) ===" -ForegroundColor Cyan
# Best-effort: em ambiente não-Windows (ex.: CI/dev fora do Windows) variáveis como
# $env:LOCALAPPDATA/$env:USERPROFILE e o registro não existem — isso é esperado e não
# deve derrubar o suite (a seção é só informativa).
try {
    $cache = Get-GoogleDriveCacheInfo
    Write-Host ("  Google Drive instalado: {0} | content_cache total: {1}" -f $cache.installed, $cache.totalFormatted) -ForegroundColor DarkGray
    $vols = Get-GoogleDriveStreamVolumes
    Write-Host ("  Volumes Stream detectados: {0}" -f (($vols | ForEach-Object { $_.letter }) -join ', ')) -ForegroundColor DarkGray
} catch {
    Write-Host ("  (detecção ao vivo de Google Drive indisponível neste ambiente: {0})" -f $_.Exception.Message) -ForegroundColor DarkGray
}
try {
    $ic = Get-CaminhosICloud
    Write-Host ("  Pastas iCloud Drive detectadas: {0}" -f (($ic -join ', '))) -ForegroundColor DarkGray
} catch {
    Write-Host ("  (detecção ao vivo de iCloud Drive indisponível neste ambiente: {0})" -f $_.Exception.Message) -ForegroundColor DarkGray
}

Write-Host ""
$summaryColor = 'Green'; if ($script:Fail -gt 0) { $summaryColor = 'Red' }
Write-Host ("Resultado: {0} passou, {1} falhou." -f $script:Pass, $script:Fail) -ForegroundColor $summaryColor
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
