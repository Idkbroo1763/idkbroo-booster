#define AppName "SoundLift"
#define AppVersion "1.1.0"
#define AppPublisher "idkbroo"
#define AppExeName "SoundLift.exe"

[Setup]
AppId={{6C485E28-1973-4E4B-89CC-C23DE2C33A2A}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\SoundLift
DefaultGroupName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
OutputDir=dist
OutputBaseFilename=SoundLift Setup
SetupIconFile=SoundLift.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
Source: "dist\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\SoundLift.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Asztali parancsikon létrehozása"; GroupDescription: "További lehetőségek:"; Flags: unchecked

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{#AppName} indítása"; Flags: nowait postinstall skipifsilent
