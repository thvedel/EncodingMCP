unit Encoding.CacheManager;

/// <summary>
///   Manager that maintains TEncodingCache instances per sidecar directory.
///   A file belongs to the nearest existing sidecar between its folder and the
///   outermost workspace root; without one it belongs to the outermost sidecar,
///   so no new sidecars appear in subfolders. Caches are loaded lazily on first
///   use, reloaded when changed on disk and saved on Flush or Free.
/// </summary>

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Encoding.Types,
  Encoding.Cache;

type
  TCacheManager = class
  strict private
    FCaches: TObjectDictionary<string, TEncodingCache>;
    function GetCache(const ADirectory: string): TEncodingCache;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>
    ///   Returns the sidecar chain for a file or directory: the nearest
    ///   existing sidecar first and the outermost workspace sidecar last. Parent
    ///   links are refreshed and sidecars changed on disk are reloaded.
    /// </summary>
    function GetChain(const APath: string): TArray<TEncodingCache>;
    /// <summary>
    ///   Returns the owning cache + relative path for an absolute file path.
    /// </summary>
    procedure Resolve(const AAbsolutePath: string;
      out ACache: TEncodingCache; out ARelativePath: string);
    /// <summary>Returns the outermost sidecar for a file or directory, where pattern overrides are stored.</summary>
    function ResolveOutermost(const APath: string): TEncodingCache;
    /// <summary>Writes all dirty caches to disk.</summary>
    procedure FlushAll;
  end;

implementation

uses
  System.IOUtils,
  Encoding.Workspace,
  MCP.Logging;

function HasSidecar(const ADirectory: string): Boolean;
begin
  Result := TFile.Exists(TPath.Combine(ADirectory, CACHE_FILE_NAME)) or
    TFile.Exists(TPath.Combine(ADirectory, LEGACY_CACHE_FILE_NAME));
end;

function IsAtOrBelow(const ADirectory, ARoot: string): Boolean;
var
  LRoot: string;
begin
  LRoot := IncludeTrailingPathDelimiter(ARoot);
  Result := SameText(Copy(IncludeTrailingPathDelimiter(ADirectory), 1, Length(LRoot)), LRoot);
end;

{ TCacheManager }

constructor TCacheManager.Create;
begin
  inherited;
  FCaches := TObjectDictionary<string, TEncodingCache>.Create([doOwnsValues]);
end;

destructor TCacheManager.Destroy;
begin
  FlushAll;
  FCaches.Free;
  inherited;
end;

function TCacheManager.GetCache(const ADirectory: string): TEncodingCache;
var
  LKey: string;
begin
  LKey := IncludeTrailingPathDelimiter(TPath.GetFullPath(ADirectory)).ToLower;
  if not FCaches.TryGetValue(LKey, Result) then
  begin
    Result := TEncodingCache.Create(ExcludeTrailingPathDelimiter(TPath.GetFullPath(ADirectory)));
    FCaches.Add(LKey, Result);
  end;
end;

function TCacheManager.GetChain(const APath: string): TArray<TEncodingCache>;
var
  LFull, LOuter, LDir, LParent: string;
  LDirs: TList<string>;
  I: Integer;
begin
  LFull := TPath.GetFullPath(APath);
  LOuter := ExcludeTrailingPathDelimiter(FindOutermostRoot(LFull));
  if TDirectory.Exists(LFull) then
    LDir := ExcludeTrailingPathDelimiter(LFull)
  else
    LDir := TPath.GetDirectoryName(LFull);
  LDirs := TList<string>.Create;
  try
    // Existing sidecars between the path and the outermost root, nearest first
    if IsAtOrBelow(LDir, LOuter) then
      while not SameText(LDir, LOuter) do
      begin
        if HasSidecar(LDir) then
          LDirs.Add(LDir);
        LParent := TPath.GetDirectoryName(LDir);
        if (LParent = '') or SameText(LParent, LDir) then
          Break;
        LDir := LParent;
      end;
    LDirs.Add(LOuter);
    SetLength(Result, LDirs.Count);
    for I := 0 to LDirs.Count - 1 do
      Result[I] := GetCache(LDirs[I]);
  finally
    LDirs.Free;
  end;
  for I := 0 to High(Result) do
  begin
    if I < High(Result) then
      Result[I].Parent := Result[I + 1]
    else
      Result[I].Parent := nil;
    Result[I].ReloadIfChanged;
  end;
end;

procedure TCacheManager.Resolve(const AAbsolutePath: string;
  out ACache: TEncodingCache; out ARelativePath: string);
begin
  ACache := GetChain(AAbsolutePath)[0];
  ARelativePath := MakeRelativePath(ACache.WorkspaceRoot, AAbsolutePath);
end;

function TCacheManager.ResolveOutermost(const APath: string): TEncodingCache;
var
  LChain: TArray<TEncodingCache>;
begin
  LChain := GetChain(APath);
  Result := LChain[High(LChain)];
end;

procedure TCacheManager.FlushAll;
var
  LCache: TEncodingCache;
begin
  for LCache in FCaches.Values do
  begin
    try
      LCache.Save;
    except
      on E: Exception do
        TLog.Warning('Failed to save cache for %s: %s', [LCache.WorkspaceRoot, E.Message]);
    end;
  end;
end;

end.
