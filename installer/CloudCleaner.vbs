' CloudCleaner.vbs — launcher escondido do CloudCleaner.ps1
'
' Por quê: "powershell.exe -WindowStyle Hidden" ainda pode piscar uma janela preta
' por uma fração de segundo em algumas versões do Windows. Rodar o PowerShell via
' WScript.Shell.Run com o parâmetro de janela = 0 (oculta) é o jeito que de fato não
' mostra janela nenhuma — é o mesmo truque usado por instaladores para "modo silencioso".
'
' O atalho (Área de Trabalho / Menu Iniciar) aponta pra ESTE arquivo (via wscript.exe),
' com o ícone customizado do CloudCleaner (o .vbs em si não carrega ícone próprio — quem
' define o ícone visível é o atalho .lnk, criado pelo instalador com IconFilename).
'
' Diagnóstico (task #2760/rework — "instalei mas nada aconteceu"): rodando 100% oculto,
' se ESTE passo falhar (objeto COM indisponível, caminho não resolvido, WScript.Shell.Run
' rejeitando o comando) o usuário não via absolutamente nada — nem o CloudCleaner.ps1
' chegava a rodar, então nem o log dele existiria. "On Error Resume Next" evita que o
' .vbs simplesmente pare sem deixar rastro; qualquer erro aqui vai para um .log ao lado
' do launcher.
On Error Resume Next

Set fso = CreateObject("Scripting.FileSystemObject")
If Err.Number <> 0 Then WScript.Quit 1 ' nem FileSystemObject deu certo — não há onde logar; desiste.

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = fso.BuildPath(scriptDir, "CloudCleaner.ps1")
logPath = fso.BuildPath(scriptDir, "CloudCleaner-launch-error.log")

Set objShell = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """"

Err.Clear
' 0 = janela oculta; False = não espera o processo terminar (o instalador/atalho volta na hora).
objShell.Run cmd, 0, False

If Err.Number <> 0 Then
    LogLaunchError "Falha ao iniciar '" & cmd & "': erro " & Err.Number & " - " & Err.Description
End If

Sub LogLaunchError(message)
    On Error Resume Next
    Dim f
    Set f = fso.OpenTextFile(logPath, 8, True) ' 8 = ForAppending; True = cria se não existir
    f.WriteLine Now & " - " & message
    f.Close
End Sub
