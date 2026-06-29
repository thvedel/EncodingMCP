unit Encoding.Workspace;

/// <summary>
///   Workspace root detection. Finds the nearest directory containing a marker
///   (.git, .windsurf, *.dproj, *.groupproj, .svn) by traversing up from a given file.
/// </summary>

interface

uses
  System.SysUtils;

/// <summary>
///   Finds the workspace root for the given path. If no marker is found,
///   the directory of the path is returned.
/// </summary>
function FindWorkspaceRoot(const APath: string): string;

/// <summary>
///   Returns a relative path from the workspace root to the target file. Uses '/'
///   as separator for portability in the sidecar cache.
/// </summary>
function MakeRelativePath(const AWorkspaceRoot, AAbsolutePath: string): string;

/// <summary>
///   Validates that APath resolves to a location within its workspace root.
///   Raises an exception if the path contains directory traversal components
///   that would place it outside the workspace.
/// </summary>
procedure ValidatePathInWorkspace(const APath: string);

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
  // Delphi project markers
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
      // Access error on protected directories - continue upward
    end;
    LParent := TPath.GetDirectoryName(LDir);
    if (LParent = '') or (LParent = LDir) then
      Break;
    LDir := LParent;
  end;
  // No marker found - use the file's directory
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

procedure ValidatePathInWorkspace(const APath: string);
var
  LResolved, LRoot: string;
begin
  LResolved := TPath.GetFullPath(APath);
  LRoot := IncludeTrailingPathDelimiter(FindWorkspaceRoot(LResolved));
  if not SameText(Copy(LResolved, 1, Length(LRoot)), LRoot) then
    raise Exception.CreateFmt(
      'Path "%s" is outside workspace root "%s"', [APath, LRoot]);
end;

end.
