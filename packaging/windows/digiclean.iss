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
;    size, icon and support links.
;  * Updates: when DigiClean is already installed, Setup says "Update
;    DigiClean <old> to <new>", reuses the previous install mode, folder and
;    shortcut choices without asking again, closes a running DigiClean (and
;    the background checker), replaces the program in place and removes app
;    files the new version no longer ships. Settings, the Recovery Bin and
;    the daily background check are kept. Installing an older version over a
;    newer one asks first.
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
; Close a running DigiClean (and digiclean-check) before files are replaced
; or removed. "force" ends it if it doesn't close by itself, so an update
; never stops halfway or needs a restart of Windows.
CloseApplications=force
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

[InstallDelete]
; Updates: the previous version's app assets (fonts, images, shaders) go
; first, so files a new version dropped don't linger. Only on an update, and
; only this DigiClean-specific folder, never anything else in {app}.
Type: filesandordirs; Name: "{app}\data\flutter_assets"; Check: IsUpdate

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Comment: "Find and remove duplicate files and folders"
; On an update, a desktop shortcut the user deleted is not brought back.
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Comment: "Find and remove duplicate files and folders"; Tasks: desktopicon; Check: KeepDesktopIcon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Remove the daily background check if the user turned it on.
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /F /TN ""DigiClean\Background check"""; Flags: runhidden; RunOnceId: "RemoveBackgroundCheck"

[Code]
const
  // Where Setup records the installed version; the GUID must match AppId.
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8F3A2C1E-6B4D-4E7A-9C2F-1D5E8A7B3C40}_is1';
  NewVersion = '{#AppVersion}';

var
  // The version already installed in this install mode; '' on a new install.
  PrevVersion: String;

function IsUpdate: Boolean;
begin
  Result := PrevVersion <> '';
end;

function KeepDesktopIcon: Boolean;
begin
  Result := not IsUpdate or FileExists(ExpandConstant('{autodesktop}\{#AppName}.lnk'));
end;

// Takes the next dot-separated number off S ("1.10.0" -> 1, S = "10.0").
function NextPart(var S: String): Integer;
var
  P: Integer;
begin
  P := Pos('.', S);
  if P = 0 then P := Length(S) + 1;
  Result := StrToIntDef(Copy(S, 1, P - 1), 0);
  Delete(S, 1, P);
end;

// < 0, 0 or > 0 when version A is older than, equal to or newer than B.
function CompareVersions(A, B: String): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to 4 do
  begin
    Result := NextPart(A) - NextPart(B);
    if Result <> 0 then Exit;
  end;
end;

function InitializeSetup: Boolean;
begin
  Result := True;
  // HKA is HKLM for "all users" and HKCU for "me only"; the install mode is
  // already settled here (UsePreviousPrivileges picks the previous one).
  if not RegQueryStringValue(HKA, UninstallKey, 'DisplayVersion', PrevVersion) then
    PrevVersion := '';
  if IsUpdate then
    Log('Updating DigiClean ' + PrevVersion + ' to ' + NewVersion)
  else
    Log('New installation of DigiClean ' + NewVersion);

  if IsUpdate and (CompareVersions(PrevVersion, NewVersion) > 0) then
    Result := SuppressibleMsgBox(
      'A newer version of DigiClean (' + PrevVersion + ') is already installed.' + #13#10#13#10 +
      'Replace it with the older version ' + NewVersion + '?',
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDYES) = IDYES;
end;

procedure InitializeWizard;
begin
  if not IsUpdate then Exit;
  if CompareVersions(PrevVersion, NewVersion) = 0 then
  begin
    WizardForm.WelcomeLabel1.Caption := 'Reinstall {#AppName}';
    WizardForm.WelcomeLabel2.Caption :=
      '{#AppName} ' + NewVersion + ' is already installed on this computer. ' +
      'Setup will reinstall it.';
  end
  else
  begin
    WizardForm.WelcomeLabel1.Caption := 'Update {#AppName}';
    WizardForm.WelcomeLabel2.Caption :=
      '{#AppName} ' + PrevVersion + ' is installed on this computer. ' +
      'Setup will update it to version ' + NewVersion + '.';
  end;
  WizardForm.WelcomeLabel2.Caption := WizardForm.WelcomeLabel2.Caption + #13#10#13#10 +
    'Your settings, Recovery Bin and background check are kept. ' +
    'If {#AppName} is open, Setup closes it first.' + #13#10#13#10 +
    'Click Next to continue, or Cancel to exit Setup.';
end;

// An update keeps the previous folder and shortcut choices: no need to ask.
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := IsUpdate and (PageID = wpSelectTasks);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  // A reinstall of the same version keeps Setup's usual wording.
  if not IsUpdate or (CompareVersions(PrevVersion, NewVersion) = 0) then Exit;
  if CurPageID = wpReady then
  begin
    WizardForm.PageNameLabel.Caption := 'Ready to Update';
    WizardForm.PageDescriptionLabel.Caption :=
      'Setup is now ready to update {#AppName} on your computer.';
    WizardForm.ReadyLabel.Caption :=
      'Click Update to update {#AppName} ' + PrevVersion + ' to version ' + NewVersion + '.';
    WizardForm.NextButton.Caption := 'Update';
  end
  else if CurPageID = wpInstalling then
  begin
    WizardForm.PageNameLabel.Caption := 'Updating';
    WizardForm.PageDescriptionLabel.Caption :=
      'Please wait while Setup updates {#AppName} on your computer.';
  end
  else if CurPageID = wpFinished then
  begin
    WizardForm.FinishedHeadingLabel.Caption := '{#AppName} is up to date';
    WizardForm.FinishedLabel.Caption :=
      '{#AppName} has been updated to version ' + NewVersion + '.';
  end;
end;
