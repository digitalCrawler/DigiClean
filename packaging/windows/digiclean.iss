; Inno Setup script for the DigiClean Windows installer
; (DigiClean-Windows-Setup.exe). Built by packaging/windows/package.ps1,
; which passes AppVersion, SourceDir, OutputDir, AppURL, Publisher and,
; when a certificate is configured, Sign.
;
; What the installer does:
;  * First screen: "Install for all users (recommended)" — needs administrator
;    rights (UAC prompt), installs to Program Files and adds the Start menu
;    entry for everyone — or "Install for me only" (no admin, installs to
;    %LOCALAPPDATA%\Programs). Silent installs choose with /ALLUSERS or
;    /CURRENTUSER.
;  * Start menu entry (always) and desktop shortcut (ticked by default).
;  * Settings › Apps / Programs and Features entry with publisher, version,
;    size, icon and support links; upgrades in place (same AppId).
;  * Uninstall removes the program, its shortcuts and the optional daily
;    background check. Settings and the Recovery Bin in the user's profile
;    are kept, like most Windows apps do.

#define AppName "DigiClean"
#define AppExe "digiclean.exe"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif
#ifndef Publisher
  #define Publisher "DigiClean"
#endif
#ifndef AppURL
  #define AppURL "https://github.com"
#endif

[Setup]
; Never change AppId: Windows uses it to recognise upgrades.
AppId={{8F3A2C1E-6B4D-4E7A-9C2F-1D5E8A7B3C40}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#Publisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
AppCopyright=Copyright (C) {#Publisher}
AppComments=Find and remove duplicate files and folders safely.
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
VersionInfoCompany={#Publisher}
VersionInfoDescription={#AppName} Setup
VersionInfoProductName={#AppName}

; Install for all users by default (administrator rights); the first page
; lets the user switch to "Install for me only" instead.
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog commandline
UsePreviousPrivileges=yes
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
DisableWelcomePage=no

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=DigiClean-Windows-Setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=no
; Close a running DigiClean before files are replaced or removed.
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
#ifdef Sign
; package.ps1 passes /Ssigntool=...; signs the installer and the uninstaller.
SignTool=signtool
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Comment: "Find and remove duplicate files and folders"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Comment: "Find and remove duplicate files and folders"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Remove the daily background check if the user turned it on.
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /F /TN ""DigiClean\Background check"""; Flags: runhidden; RunOnceId: "RemoveBackgroundCheck"
