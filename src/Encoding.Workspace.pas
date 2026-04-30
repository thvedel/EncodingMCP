unit Encoding.Workspace;

/// <summary>
///   Workspace-rod detektion. Finder den nærmeste mappe der indeholder en marker
///   (.git, .windsurf, *.dproj, *.groupproj, .svn) ved at gå op fra en given fil.
/// </summary>

interface

uses
  System.SysUtils;

/// <summary>
///   Finder workspace-rod for den givne sti. Hvis ingen marker findes,
///   returneres mappen for stien.
/// </summary>
function FindWorkspaceRoot(const APath: string): string;

/// <summary>
///   Returnerer en relativ sti fra workspace-rod til target-fil. Bruger '/' som
///   separator for portabilitet i sidecar-cachen.
/// </summary>
function MakeRelativePath(const AWorkspaceRoot, AAbsolutePath: string): string;

implementation

uses
  System.IOUtils,
  System.Types;

function HasMarker(const ADir: string): Boolean;
var
  LFiles: TStringDynArray;
begin
  if TDirectory.Exists(TPath.Combine(ADir, '.git')) or
     TFile.Exists(TPath.Combine(ADir, '.git')) then
    Exit(True);
  if TDirectory.Exists(TPath.Combine(ADir, '.windsurf')) then
    Exit(True);
  if TDirectory.Exists(TPath.Combine(ADir, '.svn')) then
    Exit(True);
  if TDirectory.Exists(TPath.Combine(ADir, '.hg')) then
    Exit(True);
  // Delphi-projekt markører
  LFiles := TDirectory.GetFiles(ADir, '*.dproj');
  if Length(LFiles) > 0 then
    Exit(True);
  LFiles := TDirectory.GetFiles(ADir, '*.groupproj');
  if Length(LFiles) > 0 then
    Exit(True);
  Result := False;
end;

function FindWorkspaceRoot(const APath: string): string;
var
  LDir, LParent: string;
begin
  if TFile.Exists(APath) then
    LDir := TPath.GetDirectoryName(APath)
  else if TDirectory.Exists(APath) then
    LDir := APath
  else
    LDir := TPath.GetDirectoryName(APath);
  if LDir = '' then
    Exit(TPath.GetDirectoryName(APath));
  while LDir <> '' do
  begin
    try
      if HasMarker(LDir) then
        Exit(LDir);
    except
      // Adgangsfejl på protected mapper - fortsæt opad
    end;
    LParent := TPath.GetDirectoryName(LDir);
    if (LParent = '') or (LParent = LDir) then
      Break;
    LDir := LParent;
  end;
  // Ingen marker fundet - brug filens mappe
  Result := TPath.GetDirectoryName(APath);
end;

function MakeRelativePath(const AWorkspaceRoot, AAbsolutePath: string): string;
var
  LRoot, LAbs: string;
begin
  LRoot := IncludeTrailingPathDelimiter(TPath.GetFullPath(AWorkspaceRoot));
  LAbs := TPath.GetFullPath(AAbsolutePath);
  if SameText(Copy(LAbs, 1, Length(LRoot)), LRoot) then
    Result := Copy(LAbs, Length(LRoot) + 1, MaxInt)
  else
    Result := LAbs;
  Result := Result.Replace('\', '/');
end;

end.
