' CloudCleaner.vbs - launcher escondido do CloudCleaner.ps1
'
' POR QUE ESTE ARQUIVO EXISTE
'   "powershell.exe -WindowStyle Hidden" ainda pode piscar uma janela preta por uma
'   fracao de segundo em algumas versoes do Windows. Rodar o PowerShell via
'   WScript.Shell.Run com o parametro de janela = 0 (oculta) e o jeito que de fato nao
'   mostra janela nenhuma.
'
'   O atalho (Area de Trabalho / Menu Iniciar) aponta pra ESTE arquivo (via wscript.exe),
'   com o icone customizado do CloudCleaner (o .vbs em si nao carrega icone proprio - quem
'   define o icone visivel e o atalho .lnk, criado pelo instalador com IconFilename).
'
' POR QUE ELE CONFIRMA QUE O PROGRAMA SUBIU (task TaskHub #2760)
'   Historico: o CloudCleaner instalado "nao abria" - clicar no atalho nao fazia
'   absolutamente nada. A causa raiz era um erro de PARSE do CloudCleaner.ps1 no Windows
'   PowerShell 5.1 (arquivo UTF-8 sem BOM, ver o cabecalho de tests/Encoding.Tests.ps1).
'   Como o script nem chegava a executar a primeira linha, o log e a caixa de erro que o
'   PROPRIO script grava nunca aconteciam - e o launcher, que so mandava rodar e ia
'   embora, tambem nao percebia nada de errado. Resultado: silencio absoluto pro usuario.
'
'   Por isso este launcher nao "manda rodar e esquece": depois de iniciar o PowerShell,
'   ele ESPERA o servidor local responder. Se em ate ~25 segundos o CloudCleaner nao
'   subir, ele mostra uma mensagem na tela explicando que nao abriu e onde olhar - em vez
'   de deixar o usuario com "nao aconteceu nada".
'
' Este arquivo e ASCII puro de proposito (sem acentos): assim ele nao depende de
' interpretacao de codepage do Windows Script Host.

Option Explicit

Const APP_URL          = "http://localhost:8080/"
Const STARTUP_TIMEOUT  = 25   ' segundos que esperamos o servidor responder
Const POLL_INTERVAL_MS = 1000

Dim fso, objShell, scriptDir, ps1Path, launchLogPath, errorLogPath, cmd

On Error Resume Next

Set fso = CreateObject("Scripting.FileSystemObject")
If Err.Number <> 0 Then WScript.Quit 1 ' nem FileSystemObject deu certo - nao ha onde logar; desiste.

scriptDir     = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path       = fso.BuildPath(scriptDir, "CloudCleaner.ps1")
launchLogPath = fso.BuildPath(scriptDir, "CloudCleaner-launch-error.log")
errorLogPath  = fso.BuildPath(scriptDir, "CloudCleaner-error.log")

If Not fso.FileExists(ps1Path) Then
    LogLaunchError "Arquivo nao encontrado: " & ps1Path
    MsgBox "O CloudCleaner nao pode abrir porque um arquivo do programa esta faltando:" & vbCrLf & vbCrLf & _
           ps1Path & vbCrLf & vbCrLf & _
           "Reinstale o CloudCleaner para corrigir.", vbCritical, "CloudCleaner"
    WScript.Quit 1
End If

Set objShell = CreateObject("WScript.Shell")
If Err.Number <> 0 Then
    LogLaunchError "CreateObject(WScript.Shell) falhou: erro " & Err.Number & " - " & Err.Description
    MsgBox "O CloudCleaner nao conseguiu iniciar (Windows Script Host indisponivel).", vbCritical, "CloudCleaner"
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1Path & """"

Err.Clear
' 0 = janela oculta; False = nao espera o processo terminar (o servidor roda ate o usuario fechar).
objShell.Run cmd, 0, False

If Err.Number <> 0 Then
    LogLaunchError "Falha ao iniciar '" & cmd & "': erro " & Err.Number & " - " & Err.Description
    MsgBox "O CloudCleaner nao conseguiu iniciar." & vbCrLf & vbCrLf & _
           "Erro " & Err.Number & ": " & Err.Description, vbCritical, "CloudCleaner"
    WScript.Quit 1
End If
Err.Clear

' --- Confirma que o programa REALMENTE subiu -------------------------------------
' Se ja houver uma instancia rodando (usuario clicou no atalho duas vezes), o teste
' abaixo responde na primeira tentativa e saimos em silencio - que e o certo.
If WaitForApp() Then
    WScript.Quit 0
End If

' Nao subiu. Mostra o motivo em vez de deixar "nao aconteceu nada".
Dim detalhe
detalhe = TailOfLog(errorLogPath, 12)
If Len(detalhe) = 0 Then detalhe = TailOfLog(launchLogPath, 12)

Dim msg
msg = "O CloudCleaner nao conseguiu abrir." & vbCrLf & vbCrLf & _
      "O programa foi iniciado, mas nao respondeu em " & STARTUP_TIMEOUT & " segundos."
If Len(detalhe) > 0 Then
    msg = msg & vbCrLf & vbCrLf & "Detalhes:" & vbCrLf & detalhe
Else
    msg = msg & vbCrLf & vbCrLf & _
          "Nenhum detalhe foi registrado. Verifique se o endereco " & APP_URL & _
          " esta sendo usado por outro programa."
End If
msg = msg & vbCrLf & vbCrLf & "Pasta do programa:" & vbCrLf & scriptDir

MsgBox msg, vbCritical, "CloudCleaner"
WScript.Quit 1

' ---------------------------------------------------------------------------------

' Espera o servidor local responder. True = subiu; False = estourou o tempo.
Function WaitForApp()
    Dim i, http
    WaitForApp = False
    For i = 1 To STARTUP_TIMEOUT
        WScript.Sleep POLL_INTERVAL_MS
        On Error Resume Next
        Set http = CreateObject("MSXML2.XMLHTTP")
        If Err.Number = 0 Then
            http.open "GET", APP_URL, False
            http.send
            If Err.Number = 0 Then
                If http.status = 200 Then
                    WaitForApp = True
                    Exit Function
                End If
            End If
        End If
        Err.Clear
    Next
End Function

' Le as ultimas N linhas de um arquivo de log (string vazia se nao existir/estiver vazio).
Function TailOfLog(path, maxLines)
    Dim f, linhas, i, inicio, saida
    TailOfLog = ""
    On Error Resume Next
    If Not fso.FileExists(path) Then Exit Function
    Set f = fso.OpenTextFile(path, 1)
    If Err.Number <> 0 Then Exit Function
    linhas = Split(f.ReadAll, vbLf)
    f.Close
    If Err.Number <> 0 Then Exit Function
    inicio = UBound(linhas) - maxLines + 1
    If inicio < 0 Then inicio = 0
    saida = ""
    For i = inicio To UBound(linhas)
        If Len(Trim(linhas(i))) > 0 Then saida = saida & Trim(linhas(i)) & vbCrLf
    Next
    TailOfLog = saida
End Function

Sub LogLaunchError(message)
    On Error Resume Next
    Dim f
    Set f = fso.OpenTextFile(launchLogPath, 8, True) ' 8 = ForAppending; True = cria se nao existir
    f.WriteLine Now & " - " & message
    f.Close
End Sub
