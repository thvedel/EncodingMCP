unit Encoding.Workspace;

/// <summary>
///   Workspace root detection and access control.
///
///   The server operates on an explicit set of allowed workspace roots, which is
///   configured at startup (command line, ENCODING_MCP_WORKSPACE, current
///   directory) and may be extended by roots advertised by the MCP client during
///   "initialize". Every tool validates its path arguments against this set, so a
///   client cannot reach files outside the configured workspaces.
///
///   Within an allowed root, FindWorkspaceRoot locates the nearest directory
///   containing a marker (.git, .windsurf, *.dproj, *.groupproj, .svn, .hg) in
///   order to place the sidecar cache sensibly.
/// </summary>

interface

uses
  System.SysUtils;

type
  /// <summary>
  ///   Raised when a requested path resolves outside every allowed workspace root.
  /// </summary>
  EWorkspaceViolation = class(Exception);

/// <summary>
///   Replaces the set of allowed workspace roots. Entries that are empty or do
///   not name an existing directory are ignored. Passing an empty set puts the
///   unit in marker-discovery mode (see ValidatePathInWorkspace).
/// </summary>
procedure SetWorkspaceRoots(const ARoots: array of string);

/// <summary>
///   Adds a single allowed workspace root. Ignored if empty, non-existent or
///   already covered by an existing root.
/// </summary>
function AddWorkspaceRoot(const ARoot: string): Boolean;

/// <summary>
///   Returns the configured allowed roots as absolute paths without a trailing
///   path delimiter. Empty when no roots have been configured.
/// </summary>
function GetWorkspaceRoots: TArray<string>;

/// <summary>
///   Returns the root that should own workspace-wide state (such as extension
///   overrides in the sidecar cache): the first configured root, or the
///   marker-based root of the current directory when none is configured.
/// </summary>
function PrimaryWorkspaceRoot: string;

/// <summary>
///   Returns True if APath resolves to a location inside one of the allowed
///   workspace roots. When no roots are configured, returns True only if a
///   workspace marker is found at or above the path.
/// </summary>
function IsPathInWorkspace(const APath: string): Boolean;

/// <summary>
///   Finds the workspace root for the given path. If no marker is found,
///   the enclosing allowed root is returned, falling back to the directory of
///   the path. The search never ascends above the enclosing allowed root.
/// </summary>
function FindWorkspaceRoot(const APath: string): string;

/// <summary>
///   Returns the outermost workspace directory for APath. It holds pattern
///   overrides and receives new sidecar entries: the enclosing configured root,
///   or without configured roots the nearest version-control root (.git, .svn,
///   .hg) at or above the path, falling back to FindWorkspaceRoot.
/// </summary>
function FindOutermostRoot(const APath: string): string;

/// <summary>
///   Returns a relative path from the workspace root to the target file. Uses '/'
///   as separator for portability in the sidecar cache.
/// </summary>
function MakeRelativePath(const AWorkspaceRoot, AAbsolutePath: string): string;

/// <summary>
///   Validates that APath resolves to a location within an allowed workspace
///   root. Raises EWorkspaceViolation otherwise. Directory traversal ('..') is
///   resolved before the check, so crafted paths cannot escape.
/// </summary>
procedure ValidatePathInWorkspace(const APath: string);

implementation

uses
  System.IOUtils,
  System.Types;

var
  // Allowed roots, normalized to absolute paths with a trailing path delimiter.
  GWorkspaceRoots: TArray<string>;

function NormalizeRoot(const ARoot: string): string;
begin
  if ARoot = '' then
    Exit('');
  try
    Result := IncludeTrailingPathDelimiter(
      ExcludeTrailingPathDelimiter(TPath.GetFullPath(ARoot)));
  except
    Result := '';
  end;
end;

/// <summary>
///   True if AFullPath (absolute, normalized) lies at or below ARoot, where
///   ARoot ends with a path delimiter. Appending a delimiter to the candidate
///   prevents "C:\Proj" from matching the sibling directory "C:\Project2".
/// </summary>
function PathIsUnderRoot(const AFullPath, ARoot: string): Boolean;
var
  LCandidate: string;
begin
  if (AFullPath = '') or (ARoot = '') then
    Exit(False);
  LCandidate := IncludeTrailingPathDelimiter(AFullPath);
  Result := SameText(Copy(LCandidate, 1, Length(ARoot)), ARoot);
end;

procedure SetWorkspaceRoots(const ARoots: array of string);
var
  I: Integer;
begin
  SetLength(GWorkspaceRoots, 0);
  for I := Low(ARoots) to High(ARoots) do
    AddWorkspaceRoot(ARoots[I]);
end;

function AddWorkspaceRoot(const ARoot: string): Boolean;
var
  LRoot: string;
  I: Integer;
begin
  LRoot := NormalizeRoot(ARoot);
  if LRoot = '' then
    Exit(False);
  if not TDirectory.Exists(LRoot) then
    Exit(False);
  for I := 0 to High(GWorkspaceRoots) do
    if SameText(GWorkspaceRoots[I], LRoot) then
      Exit(False);
  SetLength(GWorkspaceRoots, Length(GWorkspaceRoots) + 1);
  GWorkspaceRoots[High(GWorkspaceRoots)] := LRoot;
  Result := True;
end;

function GetWorkspaceRoots: TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, Length(GWorkspaceRoots));
  for I := 0 to High(GWorkspaceRoots) do
    Result[I] := ExcludeTrailingPathDelimiter(GWorkspaceRoots[I]);
end;

/// <summary>
///   Returns the allowed root containing AFullPath (with trailing delimiter), or
///   '' if there is none. The longest match wins so nested roots resolve to the
///   most specific one.
/// </summary>
function EnclosingRoot(const AFullPath: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(GWorkspaceRoots) do
    if PathIsUnderRoot(AFullPath, GWorkspaceRoots[I]) and
       (Length(GWorkspaceRoots[I]) > Length(Result)) then
      Result := GWorkspaceRoots[I];
end;

function HasVcsMarker(const ADir: string): Boolean;
begin
  Result := TDirectory.Exists(TPath.Combine(ADir, '.git')) or
    TFile.Exists(TPath.Combine(ADir, '.git')) or
    TDirectory.Exists(TPath.Combine(ADir, '.svn')) or
    TDirectory.Exists(TPath.Combine(ADir, '.hg'));
end;

function HasMarker(const ADir: string): Boolean;
var
  LFiles: TStringDynArray;
begin
  if HasVcsMarker(ADir) then
    Exit(True);
  if TDirectory.Exists(TPath.Combine(ADir, '.windsurf')) then
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

/// <summary>
///   True if a workspace marker exists in the given path's directory or any
///   ancestor directory.
/// </summary>
function HasMarkerAtOrAbove(const AFullPath: string): Boolean;
var
  LDir, LParent: string;
begin
  if TDirectory.Exists(AFullPath) then
    LDir := AFullPath
  else
    LDir := TPath.GetDirectoryName(AFullPath);
  while LDir <> '' do
  begin
    try
      if HasMarker(LDir) then
        Exit(True);
    except
      // Access error on protected directories - continue upward
    end;
    LParent := TPath.GetDirectoryName(LDir);
    if (LParent = '') or (LParent = LDir) then
      Break;
    LDir := LParent;
  end;
  Result := False;
end;

function FindWorkspaceRoot(const APath: string): string;
var
  LDir, LParent, LLimit, LFull: string;
begin
  LFull := TPath.GetFullPath(APath);
  if TFile.Exists(LFull) then
    LDir := TPath.GetDirectoryName(LFull)
  else if TDirectory.Exists(LFull) then
    LDir := LFull
  else
    LDir := TPath.GetDirectoryName(LFull);
  if LDir = '' then
    Exit(TPath.GetDirectoryName(LFull));

  // Never ascend above the allowed root that contains the path.
  LLimit := EnclosingRoot(LFull);

  while LDir <> '' do
  begin
    try
      if HasMarker(LDir) then
        Exit(LDir);
    except
      // Access error on protected directories - continue upward
    end;
    if (LLimit <> '') and SameText(IncludeTrailingPathDelimiter(LDir), LLimit) then
      Break;
    LParent := TPath.GetDirectoryName(LDir);
    if (LParent = '') or (LParent = LDir) then
      Break;
    LDir := LParent;
  end;

  // No marker found - prefer the enclosing allowed root, else the path's directory
  if LLimit <> '' then
    Result := ExcludeTrailingPathDelimiter(LLimit)
  else
    Result := TPath.GetDirectoryName(LFull);
end;

function FindOutermostRoot(const APath: string): string;
var
  LFull, LLimit, LDir, LParent: string;
begin
  LFull := TPath.GetFullPath(APath);
  LLimit := EnclosingRoot(LFull);
  if LLimit <> '' then
    Exit(ExcludeTrailingPathDelimiter(LLimit));
  if TDirectory.Exists(LFull) then
    LDir := LFull
  else
    LDir := TPath.GetDirectoryName(LFull);
  while LDir <> '' do
  begin
    if HasVcsMarker(LDir) then
      Exit(LDir);
    LParent := TPath.GetDirectoryName(LDir);
    if (LParent = '') or (LParent = LDir) then
      Break;
    LDir := LParent;
  end;
  Result := FindWorkspaceRoot(LFull);
end;

function PrimaryWorkspaceRoot: string;
begin
  if Length(GWorkspaceRoots) > 0 then
    Result := ExcludeTrailingPathDelimiter(GWorkspaceRoots[0])
  else
    Result := FindWorkspaceRoot(GetCurrentDir);
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

function IsPathInWorkspace(const APath: string): Boolean;
var
  LResolved: string;
begin
  if APath = '' then
    Exit(False);
  try
    LResolved := TPath.GetFullPath(APath);
  except
    Exit(False);
  end;
  if LResolved = '' then
    Exit(False);

  if Length(GWorkspaceRoots) > 0 then
    Exit(EnclosingRoot(LResolved) <> '');

  // No roots configured: fall back to requiring a real workspace marker at or
  // above the path, so unrelated locations are still rejected.
  Result := HasMarkerAtOrAbove(LResolved);
end;

procedure ValidatePathInWorkspace(const APath: string);
var
  LRoots: TArray<string>;
begin
  if IsPathInWorkspace(APath) then
    Exit;
  LRoots := GetWorkspaceRoots;
  if Length(LRoots) > 0 then
    raise EWorkspaceViolation.CreateFmt(
      'Path "%s" is outside the allowed workspace root(s): %s',
      [APath, string.Join('; ', LRoots)])
  else
    raise EWorkspaceViolation.CreateFmt(
      'Path "%s" is not inside a workspace (no .git, .dproj, .groupproj, ' +
      '.windsurf, .svn or .hg marker found at or above it)', [APath]);
end;

end.
