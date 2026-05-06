unit Encoding.CacheManager;

/// <summary>
///   Manager that maintains TEncodingCache instances per workspace root.
///   Caches are loaded lazily on first use and saved on Flush or Free.
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
    function GetCacheForFile(const AAbsolutePath: string): TEncodingCache;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>
    ///   Returns cache + relative path for an absolute file path.
    /// </summary>
    procedure Resolve(const AAbsolutePath: string;
      out ACache: TEncodingCache; out ARelativePath: string);
    /// <summary>Writes all dirty caches to disk.</summary>
    procedure FlushAll;
  end;

implementation

uses
  System.IOUtils,
  Encoding.Workspace,
  MCP.Logging;

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

function TCacheManager.GetCacheForFile(const AAbsolutePath: string): TEncodingCache;
var
  LRoot, LKey: string;
begin
  LRoot := FindWorkspaceRoot(AAbsolutePath);
  LKey := IncludeTrailingPathDelimiter(TPath.GetFullPath(LRoot)).ToLower;
  if not FCaches.TryGetValue(LKey, Result) then
  begin
    Result := TEncodingCache.Create(LRoot);
    FCaches.Add(LKey, Result);
  end;
end;

procedure TCacheManager.Resolve(const AAbsolutePath: string;
  out ACache: TEncodingCache; out ARelativePath: string);
begin
  ACache := GetCacheForFile(AAbsolutePath);
  ARelativePath := MakeRelativePath(ACache.WorkspaceRoot, AAbsolutePath);
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
