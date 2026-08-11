; CloudCleaner.iss — instalador Windows (Inno Setup) do CloudCleaner
; Task TaskHub #2760 (Opção B): instalador .exe, sem a janela preta do PowerShell,
; ícone próprio, e checkbox independente pra Área de Trabalho e/ou Menu Iniciar.
;
; Compilar (Windows, com Inno Setup 6+ instalado):
;   iscc installer\CloudCleaner.iss
; -> gera installer\dist\CloudCleaner-Setup-vX.Y.Z.exe
;
; No CI (windows-latest), ver .github/workflows/build-installer.yml — instala o Inno
; Setup via Chocolatey e roda o mesmo comando.

#define MyAppName "CloudCleaner"
#define MyAppVersion "1.3.1"
#define MyAppPublisher "Grupo Valebrum"
#define MyAppURL "https://github.com/Valebrum/CloudCleaner"

[Setup]
AppId={{F0B649BF-3AC9-463F-AA60-E2BC1F8EE912}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
; Instala em Program Files se admin, ou em %LocalAppData%\Programs se usuário comum —
; sem exigir elevação (ferramenta pessoal, não precisa de admin pra instalar).
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=dist
OutputBaseFilename=CloudCleaner-Setup-v{#MyAppVersion}
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile=..\LICENSE.md

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

; As DUAS opções de atalho, cada uma com sua própria checkbox — o usuário escolhe uma,
; outra, as duas ou nenhuma (nunca trava numa escolha única). Nenhuma marcada por padrão
; força a decisão consciente na hora de instalar (padrão comum de instalador do Windows).
[Tasks]
Name: "desktopicon"; Description: "Criar atalho na Área de Trabalho"; GroupDescription: "Atalhos:"; Flags: unchecked
Name: "startmenuicon"; Description: "Criar atalho no Menu Iniciar"; GroupDescription: "Atalhos:"; Flags: checkedonce

[Files]
Source: "..\CloudCleaner.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\index.html"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\changelog.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "CloudCleaner.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "icon.ico"; DestDir: "{app}"; Flags: ignoreversion

; Os atalhos chamam wscript.exe explicitamente (em vez de confiar na associação padrão
; de .vbs) — é o host GUI do Windows Script Host, que NÃO abre janela de console (ao
; contrário de cscript.exe). É o que garante "roda escondido, sem telinha preta".
[Icons]
Name: "{autodesktop}\{#MyAppName}"; Filename: "{win}\System32\wscript.exe"; \
    Parameters: """{app}\CloudCleaner.vbs"""; WorkingDir: "{app}"; \
    IconFilename: "{app}\icon.ico"; Tasks: desktopicon
Name: "{group}\{#MyAppName}"; Filename: "{win}\System32\wscript.exe"; \
    Parameters: """{app}\CloudCleaner.vbs"""; WorkingDir: "{app}"; \
    IconFilename: "{app}\icon.ico"; Tasks: startmenuicon
Name: "{group}\Desinstalar {#MyAppName}"; Filename: "{uninstallexe}"; Tasks: startmenuicon

[Run]
; Defesa contra o "Mark of the Web" (task #2760/rework — instalador funcionou mas o
; atalho instalado "não fazia nada"): o setup.exe baixado do GitHub Releases carrega a
; marca de zona de internet (Zone.Identifier), e desde o Inno Setup 6.1 esse instalador
; PROPAGA essa marca para os arquivos que ele extrai — silenciosamente, sem avisar no
; instalador. Isso pode fazer o Windows tratar o .ps1/.vbs recém-instalados como
; "baixados da internet" para fins de política de segurança. Unblock-File remove a
; marca dos arquivos já copiados, ANTES de oferecer "Abrir agora". Roda oculto (sem
; janela) e nunca falha a instalação (o "-Command" engole o próprio erro).
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Get-ChildItem -LiteralPath '{app}' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue"""; \
    WorkingDir: "{app}"; Flags: runhidden

Filename: "{win}\System32\wscript.exe"; Parameters: """{app}\CloudCleaner.vbs"""; \
    WorkingDir: "{app}"; Description: "Abrir o {#MyAppName} agora"; \
    Flags: postinstall nowait skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
