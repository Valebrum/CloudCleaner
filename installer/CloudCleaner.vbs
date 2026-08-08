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

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = fso.BuildPath(scriptDir, "CloudCleaner.ps1")

Set objShell = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """"

' 0 = janela oculta; False = não espera o processo terminar (o instalador/atalho volta na hora).
objShell.Run cmd, 0, False
