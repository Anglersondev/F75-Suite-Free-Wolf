#define MyAppName "F75 Studio"
#define MyAppVersion "1.0"
#define MyAppExeName "F75 Studio.exe"

[Setup]
AppId={{8F4BDF24-5E09-441D-B76F-B86833B16A74}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=F75 Studio
DefaultDirName={localappdata}\Programs\F75 Studio
DefaultGroupName=F75 Studio
PrivilegesRequired=lowest
OutputDir=..\..
OutputBaseFilename=F75-Studio-Setup-1.0
SetupIconFile=f75.ico
UninstallDisplayIcon={app}\F75 Studio.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\F75 Studio.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\F75 Studio.exe.config"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LEIA-ME.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\PROTOCOLO.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\F75 Studio"; Filename: "{app}\F75 Studio.exe"
Name: "{autodesktop}\F75 Studio"; Filename: "{app}\F75 Studio.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Criar ícone na área de trabalho / Create a desktop icon"; GroupDescription: "Atalhos / Shortcuts:"; Flags: unchecked

[Run]
Filename: "{app}\F75 Studio.exe"; Description: "Abrir F75 Studio / Launch F75 Studio"; Flags: nowait postinstall skipifsilent
