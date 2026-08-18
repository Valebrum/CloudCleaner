# GoogleDriveGuardedCleanup.Tests.ps1 — TDD (Pester 5) da limpeza GUARDADA do
# content_cache do Google Drive Stream (task TaskHub #327, follow-up de #17/PR #8).
#
# Cobre as 3 salvaguardas exigidas pela task:
#   1) Confirmação FORTE (frase exata) — Test-CacheCleanupSafe
#   2) Resguardo do estado antes de apagar (mover, não apagar) — Backup-/Restore-GoogleDriveCache
#   3) Aborta em caso de atividade local recente (possível upload pendente) — Test-RecentLocalActivity
#
# ⚠️ SEGURANÇA: nenhum teste aqui toca o content_cache real do Google Drive de ninguém.
# Backup-/Restore-/Invoke- são exercitados só contra pastas FALSAS criadas no TestDrive:
# do próprio Pester (apagadas ao fim da sessão de teste). O processo real do DriveFS
# (Stop-Process/Start-Process) nunca é chamado nestes testes — é sempre injetado via
# scriptblock fake. Só um teste (Get-GoogleDriveFsProcessInfo) toca o mundo real, e é
# 100% leitura (Get-Process), sem nenhum efeito colateral.
#
# Rodar:  pwsh -NoProfile -Command "Invoke-Pester -Path .\tests\GoogleDriveGuardedCleanup.Tests.ps1 -Output Detailed"

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    . (Join-Path $here '..\CloudCleaner.ps1') -NoServe
}

Describe 'Test-RecentLocalActivity (sinal puro de atividade recente)' {
    BeforeAll {
        $now = Get-Date '2026-08-07T12:00:00Z'
    }

    It 'lista vazia -> sem atividade recente' {
        Test-RecentLocalActivity -Files @() -NowUtc $now -GraceWindowSeconds 900 | Should -BeFalse
    }

    It 'arquivo escrito 1s atrás, dentro da janela de 900s -> atividade recente' {
        $files = @([PSCustomObject]@{ LastWriteTimeUtc = $now.AddSeconds(-1) })
        Test-RecentLocalActivity -Files $files -NowUtc $now -GraceWindowSeconds 900 | Should -BeTrue
    }

    It 'arquivo escrito 1000s atrás, fora da janela de 900s -> sem atividade recente' {
        $files = @([PSCustomObject]@{ LastWriteTimeUtc = $now.AddSeconds(-1000) })
        Test-RecentLocalActivity -Files $files -NowUtc $now -GraceWindowSeconds 900 | Should -BeFalse
    }

    It 'arquivo exatamente na borda da janela (idade == janela) -> NÃO conta como recente' {
        $files = @([PSCustomObject]@{ LastWriteTimeUtc = $now.AddSeconds(-900) })
        Test-RecentLocalActivity -Files $files -NowUtc $now -GraceWindowSeconds 900 | Should -BeFalse
    }

    It 'um arquivo antigo e um recente juntos -> atividade recente (basta um)' {
        $files = @(
            [PSCustomObject]@{ LastWriteTimeUtc = $now.AddSeconds(-5000) }
            [PSCustomObject]@{ LastWriteTimeUtc = $now.AddSeconds(-10) }
        )
        Test-RecentLocalActivity -Files $files -NowUtc $now -GraceWindowSeconds 900 | Should -BeTrue
    }

    It 'ignora entradas nulas na lista sem lançar erro' {
        $files = @($null, [PSCustomObject]@{ LastWriteTimeUtc = $now.AddSeconds(-5000) })
        { Test-RecentLocalActivity -Files $files -NowUtc $now -GraceWindowSeconds 900 } | Should -Not -Throw
        Test-RecentLocalActivity -Files $files -NowUtc $now -GraceWindowSeconds 900 | Should -BeFalse
    }

    It 'timestamp no "futuro" (relógio de rede estranho) não conta como recente (idade negativa é ignorada)' {
        $files = @([PSCustomObject]@{ LastWriteTimeUtc = $now.AddSeconds(30) })
        Test-RecentLocalActivity -Files $files -NowUtc $now -GraceWindowSeconds 900 | Should -BeFalse
    }
}

Describe 'Test-CacheCleanupSafe (gate único das 3 salvaguardas)' {
    It 'confirmação errada -> NÃO seguro, mesmo com tudo mais OK' {
        $r = Test-CacheCleanupSafe -Confirm 'apagar tudo' -HasRecentActivity $false -DriveFsStopped $true
        $r.safe | Should -BeFalse
        $r.reason | Should -Match 'APAGAR CACHE'
    }

    It 'confirmação vazia -> NÃO seguro' {
        $r = Test-CacheCleanupSafe -Confirm '' -HasRecentActivity $false -DriveFsStopped $true
        $r.safe | Should -BeFalse
    }

    It 'confirmação certa mas com atividade local recente -> NÃO seguro (aborta por possível upload pendente)' {
        $r = Test-CacheCleanupSafe -Confirm 'APAGAR CACHE' -HasRecentActivity $true -DriveFsStopped $true
        $r.safe | Should -BeFalse
        $r.reason | Should -Match 'pendente'
    }

    It 'confirmação certa, sem atividade recente, mas DriveFS não parou -> NÃO seguro' {
        $r = Test-CacheCleanupSafe -Confirm 'APAGAR CACHE' -HasRecentActivity $false -DriveFsStopped $false
        $r.safe | Should -BeFalse
        $r.reason | Should -Match 'parar'
    }

    It 'confirmação certa + sem atividade recente + DriveFS parado -> SEGURO' {
        $r = Test-CacheCleanupSafe -Confirm 'APAGAR CACHE' -HasRecentActivity $false -DriveFsStopped $true
        $r.safe | Should -BeTrue
        $r.reason | Should -BeNullOrEmpty
    }

    It 'confirmação errada tem prioridade sobre os outros dois motivos (mensagem certa mesmo com tudo ruim)' {
        $r = Test-CacheCleanupSafe -Confirm 'errado' -HasRecentActivity $true -DriveFsStopped $false
        $r.safe | Should -BeFalse
        $r.reason | Should -Match 'APAGAR CACHE'
    }
}

Describe 'Backup-GoogleDriveCache / Restore-GoogleDriveCache (prova de reversibilidade)' {
    BeforeEach {
        $script:cacheDir  = Join-Path $TestDrive 'DriveFS\123456\content_cache'
        $script:backupRoot = Join-Path $TestDrive 'DriveFS\123456'
        # $TestDrive persiste pela sessão inteira do Pester (não é recriado por It) — limpa
        # qualquer resíduo de backup do teste anterior antes de montar o cenário deste.
        if (Test-Path -LiteralPath $script:backupRoot) { Remove-Item -LiteralPath $script:backupRoot -Recurse -Force }
        New-Item -ItemType Directory -Path $script:cacheDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:cacheDir 'chunk.bin') -Value 'conteudo-fake-do-cache' -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $script:cacheDir 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:cacheDir 'sub\outro.bin') -Value 'outro-conteudo' -NoNewline
    }

    It 'backup MOVE o content_cache (não copia) — a pasta original deixa de existir' {
        Backup-GoogleDriveCache -CacheDir $script:cacheDir -BackupRoot $script:backupRoot -NowProvider { Get-Date '2026-08-07T10:00:00' } | Out-Null
        Test-Path -LiteralPath $script:cacheDir | Should -BeFalse
    }

    It 'backup cria a pasta com timestamp e preserva o conteúdo (incluindo subpastas) intacto' {
        $dest = Backup-GoogleDriveCache -CacheDir $script:cacheDir -BackupRoot $script:backupRoot -NowProvider { Get-Date '2026-08-07T10:00:00' }
        $dest | Should -Be (Join-Path $script:backupRoot 'content_cache.bak-20260807-100000')
        Test-Path -LiteralPath $dest | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $dest 'chunk.bin') -Raw | Should -Be 'conteudo-fake-do-cache'
        Get-Content -LiteralPath (Join-Path $dest 'sub\outro.bin') -Raw | Should -Be 'outro-conteudo'
    }

    It 'restore devolve o content_cache ao lugar original com o MESMO conteúdo (round-trip completo = reversível)' {
        $dest = Backup-GoogleDriveCache -CacheDir $script:cacheDir -BackupRoot $script:backupRoot -NowProvider { Get-Date '2026-08-07T10:00:00' }
        Test-Path -LiteralPath $script:cacheDir | Should -BeFalse   # confirma que "sumiu" antes de restaurar

        Restore-GoogleDriveCache -BackupPath $dest -CacheDir $script:cacheDir | Out-Null

        Test-Path -LiteralPath $script:cacheDir | Should -BeTrue
        Test-Path -LiteralPath $dest | Should -BeFalse              # backup foi movido de volta, não copiado
        Get-Content -LiteralPath (Join-Path $script:cacheDir 'chunk.bin') -Raw | Should -Be 'conteudo-fake-do-cache'
        Get-Content -LiteralPath (Join-Path $script:cacheDir 'sub\outro.bin') -Raw | Should -Be 'outro-conteudo'
    }

    It 'backup lança erro claro se o content_cache não existe (nada criado)' {
        $missing = Join-Path $TestDrive 'DriveFS\999999\content_cache'
        { Backup-GoogleDriveCache -CacheDir $missing -BackupRoot $script:backupRoot } | Should -Throw '*não encontrado*'
    }

    It 'restore lança erro claro se o backup não existe' {
        $missingBackup = Join-Path $script:backupRoot 'content_cache.bak-inexistente'
        { Restore-GoogleDriveCache -BackupPath $missingBackup -CacheDir (Join-Path $TestDrive 'destino-qualquer') } | Should -Throw '*Backup não encontrado*'
    }

    It 'restore recusa sobrescrever um content_cache que já existe no destino (guarda contra perda de dado)' {
        $dest = Backup-GoogleDriveCache -CacheDir $script:cacheDir -BackupRoot $script:backupRoot -NowProvider { Get-Date '2026-08-07T10:00:00' }
        # Alguém (ou o próprio Drive) recriou um content_cache novo no meio do caminho.
        New-Item -ItemType Directory -Path $script:cacheDir -Force | Out-Null
        { Restore-GoogleDriveCache -BackupPath $dest -CacheDir $script:cacheDir } | Should -Throw '*Ja existe*'
    }
}

Describe 'Get-GoogleDriveRecentActivityFiles (I/O somente-leitura)' {
    It 'pasta inexistente -> lista vazia, sem erro' {
        { Get-GoogleDriveRecentActivityFiles -Root (Join-Path $TestDrive 'nao-existe') } | Should -Not -Throw
        $r = @(Get-GoogleDriveRecentActivityFiles -Root (Join-Path $TestDrive 'nao-existe'))
        $r.Count | Should -Be 0
    }

    It 'pasta com arquivos -> devolve objetos com LastWriteTimeUtc' {
        $root = Join-Path $TestDrive 'MyDrive'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'planilha.xlsx') -Value 'x' -NoNewline
        $r = @(Get-GoogleDriveRecentActivityFiles -Root $root)
        $r.Count | Should -Be 1
        $r[0].LastWriteTimeUtc | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-GoogleDriveFsProcessInfo (leitura real, sem efeito colateral)' {
    It 'sem o processo GoogleDriveFS rodando -> running=$false e path=$null (comportamento nesta máquina de teste)' {
        # Este teste roda numa máquina sem o Google Drive instalado/aberto (ambiente de
        # desenvolvimento) — por isso o resultado esperado É "não rodando". Não afirma nada
        # sobre a máquina de produção do usuário; só prova que a função não lança erro nem
        # inventa dado quando o processo não existe.
        if (Get-Process -Name 'GoogleDriveFS' -ErrorAction SilentlyContinue) {
            Set-ItResult -Skipped -Because 'há um GoogleDriveFS real rodando nesta máquina de teste'
            return
        }
        $info = Get-GoogleDriveFsProcessInfo
        $info.running | Should -BeFalse
        $info.path | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-LimpezaGuardadaGoogleDriveCache (orquestrador — tudo injetado, nada real)' {
    BeforeEach {
        $script:cacheDir   = Join-Path $TestDrive 'DriveFS\42\content_cache'
        $script:backupRoot = Join-Path $TestDrive 'DriveFS\42'
        if (Test-Path -LiteralPath $script:backupRoot) { Remove-Item -LiteralPath $script:backupRoot -Recurse -Force }
        New-Item -ItemType Directory -Path $script:cacheDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:cacheDir 'chunk.bin') -Value 'dado-do-usuario' -NoNewline

        # Espiões: contam chamadas sem tocar em processo real nenhum. As scriptblocks são
        # invocadas de DENTRO de Invoke-LimpezaGuardadaGoogleDriveCache (outro arquivo/escopo
        # "script"), então NÃO usam o modificador $script: no corpo — capturam aliases locais
        # via .GetNewClosure(), que preserva a referência ao mesmo objeto .NET independente de
        # qual script está executando quando a closure é chamada.
        $script:stopCalled  = [ref]$false
        $script:startCalls  = [System.Collections.Generic.List[string]]::new()
        $script:fakeExePath = Join-Path $TestDrive 'fake\GoogleDriveFS.exe'

        $stopCalledLocal  = $script:stopCalled
        $startCallsLocal  = $script:startCalls
        $fakeExePathLocal = $script:fakeExePath

        $script:fakeStop  = { $stopCalledLocal.Value = $true; return $true }.GetNewClosure()
        $script:fakeStart = { param($ExePath) $startCallsLocal.Add($ExePath) }.GetNewClosure()
        $script:fakeInfo  = { [PSCustomObject]@{ running = $true; path = $fakeExePathLocal } }.GetNewClosure()
    }

    It 'caminho feliz: confirma, para, faz backup (move) e reinicia — sucesso e content_cache reversível' {
        $r = Invoke-LimpezaGuardadaGoogleDriveCache `
            -CacheDir $script:cacheDir -Confirm 'APAGAR CACHE' -BackupRoot $script:backupRoot `
            -GetDriveFsInfo $script:fakeInfo -StopDriveFs $script:fakeStop -StartDriveFs $script:fakeStart

        $r.success | Should -BeTrue
        $r.aborted | Should -BeFalse
        Test-Path -LiteralPath $script:cacheDir | Should -BeFalse         # cache "sumiu" do lugar original
        Test-Path -LiteralPath $r.backupPath | Should -BeTrue             # ...mas está guardado, não apagado
        Get-Content -LiteralPath (Join-Path $r.backupPath 'chunk.bin') -Raw | Should -Be 'dado-do-usuario'
        $script:stopCalled.Value | Should -BeTrue
        $script:startCalls | Should -Contain $script:fakeExePath          # DriveFS foi reiniciado
    }

    It 'confirmação errada: ABORTA sem mexer em nada e sem nem tentar parar o DriveFS' {
        $r = Invoke-LimpezaGuardadaGoogleDriveCache `
            -CacheDir $script:cacheDir -Confirm 'apaga ai' -BackupRoot $script:backupRoot `
            -GetDriveFsInfo $script:fakeInfo -StopDriveFs $script:fakeStop -StartDriveFs $script:fakeStart

        $r.success | Should -BeFalse
        $r.aborted | Should -BeTrue
        $r.reason | Should -Match 'APAGAR CACHE'
        Test-Path -LiteralPath $script:cacheDir | Should -BeTrue                      # nada foi tocado
        Get-Content -LiteralPath (Join-Path $script:cacheDir 'chunk.bin') -Raw | Should -Be 'dado-do-usuario'
        $script:stopCalled.Value | Should -BeFalse                                    # nem chegou a parar o DriveFS
        $script:startCalls.Count | Should -Be 0
    }

    It 'atividade local recente detectada: ABORTA (possível upload pendente) sem parar o DriveFS nem tocar no cache' {
        $mountRoot = Join-Path $TestDrive 'MyDriveMount'
        New-Item -ItemType Directory -Path $mountRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mountRoot 'documento-recem-editado.docx') -Value 'edicao recente' -NoNewline

        $r = Invoke-LimpezaGuardadaGoogleDriveCache `
            -CacheDir $script:cacheDir -Confirm 'APAGAR CACHE' -BackupRoot $script:backupRoot -MountRoot $mountRoot `
            -GraceWindowSeconds 900 `
            -GetDriveFsInfo $script:fakeInfo -StopDriveFs $script:fakeStop -StartDriveFs $script:fakeStart

        $r.success | Should -BeFalse
        $r.aborted | Should -BeTrue
        $r.reason | Should -Match 'pendente'
        Test-Path -LiteralPath $script:cacheDir | Should -BeTrue    # o cache do usuário não foi tocado
        $script:stopCalled.Value | Should -BeFalse                  # sync nem foi interrompido à toa
    }

    It 'arquivo antigo no mount root (fora da janela de graça) NÃO aborta — segue o caminho feliz' {
        $mountRoot = Join-Path $TestDrive 'MyDriveMountAntigo'
        New-Item -ItemType Directory -Path $mountRoot -Force | Out-Null
        $oldFile = Join-Path $mountRoot 'arquivo-antigo.docx'
        Set-Content -LiteralPath $oldFile -Value 'nada de novo' -NoNewline
        (Get-Item -LiteralPath $oldFile).LastWriteTime = (Get-Date).AddDays(-30)

        $r = Invoke-LimpezaGuardadaGoogleDriveCache `
            -CacheDir $script:cacheDir -Confirm 'APAGAR CACHE' -BackupRoot $script:backupRoot -MountRoot $mountRoot `
            -GraceWindowSeconds 900 `
            -GetDriveFsInfo $script:fakeInfo -StopDriveFs $script:fakeStop -StartDriveFs $script:fakeStart

        $r.success | Should -BeTrue
        $r.aborted | Should -BeFalse
    }

    It 'falha ao parar o DriveFS: ABORTA, não apaga o cache, e tenta reiniciar o que já tinha sido tocado' {
        $stopCalledLocal = $script:stopCalled
        $fakeStopFails = { $stopCalledLocal.Value = $true; return $false }.GetNewClosure()

        $r = Invoke-LimpezaGuardadaGoogleDriveCache `
            -CacheDir $script:cacheDir -Confirm 'APAGAR CACHE' -BackupRoot $script:backupRoot `
            -GetDriveFsInfo $script:fakeInfo -StopDriveFs $fakeStopFails -StartDriveFs $script:fakeStart

        $r.success | Should -BeFalse
        $r.aborted | Should -BeTrue
        $r.reason | Should -Match 'parar'
        Test-Path -LiteralPath $script:cacheDir | Should -BeTrue
        $script:startCalls | Should -Contain $script:fakeExePath   # tenta deixar o usuário sincronizando de novo
    }

    It 'falha ao criar o resguardo (ex.: content_cache some no meio do caminho): reporta erro e tenta reiniciar o DriveFS' {
        $missingCache = Join-Path $TestDrive 'DriveFS\43\content_cache'   # nunca criado

        $r = Invoke-LimpezaGuardadaGoogleDriveCache `
            -CacheDir $missingCache -Confirm 'APAGAR CACHE' -BackupRoot (Join-Path $TestDrive 'DriveFS\43') `
            -GetDriveFsInfo $script:fakeInfo -StopDriveFs $script:fakeStop -StartDriveFs $script:fakeStart

        $r.success | Should -BeFalse
        $r.aborted | Should -BeTrue
        $r.reason | Should -Match 'resguardo'
        $script:startCalls | Should -Contain $script:fakeExePath
    }

    It 'sem MountRoot informado: não falha e apenas segue (equivalente a "sem sinal de atividade")' {
        $r = Invoke-LimpezaGuardadaGoogleDriveCache `
            -CacheDir $script:cacheDir -Confirm 'APAGAR CACHE' -BackupRoot $script:backupRoot `
            -GetDriveFsInfo $script:fakeInfo -StopDriveFs $script:fakeStop -StartDriveFs $script:fakeStart
        $r.success | Should -BeTrue
    }

    It 'quando o DriveFS não estava rodando (path=$null), não tenta reiniciar nada mas ainda assim conclui a limpeza' {
        $noProcessInfo = { [PSCustomObject]@{ running = $false; path = $null } }
        $r = Invoke-LimpezaGuardadaGoogleDriveCache `
            -CacheDir $script:cacheDir -Confirm 'APAGAR CACHE' -BackupRoot $script:backupRoot `
            -GetDriveFsInfo $noProcessInfo -StopDriveFs $script:fakeStop -StartDriveFs $script:fakeStart

        $r.success | Should -BeTrue
        $r.restarted | Should -BeFalse
        $script:startCalls.Count | Should -Be 0
    }
}
