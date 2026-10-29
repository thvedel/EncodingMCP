unit Tools.SetOverride;

/// <summary>
///   MCP tool: set_encoding_override. Sets or removes a manual encoding
///   override for a specific file or for a pattern (e.g. *.pas → Windows-1252).
///   Pattern overrides live in the outermost sidecar of the workspace.
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  MCP.Tools,
  Encoding.CacheManager;

type
  /// <summary>Raised when an override to remove does not exist.</summary>
  EOverrideNotFound = class(Exception);

  TSetOverrideTool = class(TInterfacedObject, IMcpTool)
  strict private
    FCacheManager: TCacheManager;
    function ExecuteForPath(const APath, AEncodingName: string; ARemove: Boolean): TJSONObject;
    function ExecuteForPattern(const APattern, ADirectory, AEncodingName: string;
      ARemove: Boolean): TJSONObject;
  public
    constructor Create(ACacheManager: TCacheManager);
    function GetName: string;
    function GetDescription: string;
    function BuildInputSchema: TJSONObject;
    function Execute(AArguments: TJSONObject): TJSONObject;
  end;

implementation

uses
  System.IOUtils,
  System.Generics.Collections,
  Encoding.Types,
  Encoding.Workspace,
  Encoding.Cache;

constructor TSetOverrideTool.Create(ACacheManager: TCacheManager);
begin
  inherited Create;
  FCacheManager := ACacheManager;
end;

function TSetOverrideTool.GetName: string;
begin
  Result := 'set_encoding_override';
end;

function TSetOverrideTool.GetDescription: string;
begin
  Result :=
    'Set or remove a manual encoding override for one file (path) or for all ' +
    'files matching a pattern (pattern). Pattern overrides are stored in the ' +
    'outermost sidecar (.encoding-mcp.json in the workspace root) and apply to ' +
    'all subfolders, including folders with their own .dproj; a nearer sidecar ' +
    'with a matching pattern takes precedence. Patterns without "/" match the ' +
    'file name (e.g. "*.pas"); patterns with "/" match the path relative to the ' +
    'workspace root and support "*", "?" and "**" (e.g. "src/**/*.dfm"). Other ' +
    'glob syntax is rejected. Pass remove: true (without encoding) to delete an ' +
    'override. Overrides take precedence over auto-detection except when a BOM ' +
    'is present. Manual edits of the sidecar take effect on the next call.';
end;

function TSetOverrideTool.BuildInputSchema: TJSONObject;
var
  LProps, LPath, LPattern, LDirectory, LEnc, LRemove: TJSONObject;
  LEncEnum: TJSONArray;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('type', 'object');
    LProps := TJSONObject.Create;
    Result.AddPair('properties', LProps);
    LPath := TJSONObject.Create;
    LPath.AddPair('type', 'string');
    LPath.AddPair('description',
      'Absolute path of a single file (provide either path OR pattern).');
    LProps.AddPair('path', LPath);
    LPattern := TJSONObject.Create;
    LPattern.AddPair('type', 'string');
    LPattern.AddPair('description',
      'File-name pattern (e.g. "*.pas") or path pattern relative to the ' +
      'workspace root (e.g. "src/**/*.dfm"). Supports "*", "?" and "**".');
    LProps.AddPair('pattern', LPattern);
    LDirectory := TJSONObject.Create;
    LDirectory.AddPair('type', 'string');
    LDirectory.AddPair('description',
      'Optional, pattern only: an absolute directory inside the workspace that ' +
      'selects the workspace root whose outermost sidecar holds the override. ' +
      'Defaults to the first workspace root. On remove, the pattern is removed ' +
      'from every sidecar between this directory and the outermost root.');
    LProps.AddPair('directory', LDirectory);
    LEnc := TJSONObject.Create;
    LEnc.AddPair('type', 'string');
    LEnc.AddPair('description', 'The encoding to force. Required unless remove is true.');
    LEncEnum := TJSONArray.Create;
    LEncEnum.Add('UTF-8');
    LEncEnum.Add('UTF-16LE');
    LEncEnum.Add('UTF-16BE');
    LEncEnum.Add('Windows-1252');
    LEncEnum.Add('ISO-8859-1');
    LEncEnum.Add('ISO-8859-15');
    LEncEnum.Add('ASCII');
    LEnc.AddPair('enum', LEncEnum);
    LProps.AddPair('encoding', LEnc);
    LRemove := TJSONObject.Create;
    LRemove.AddPair('type', 'boolean');
    LRemove.AddPair('description',
      'If true, remove the override for path or pattern instead of setting it.');
    LProps.AddPair('remove', LRemove);
  except
    Result.Free;
    raise;
  end;
end;

function TSetOverrideTool.Execute(AArguments: TJSONObject): TJSONObject;
var
  LPath, LPattern, LDirectory, LEncodingName: string;
  LRemove: Boolean;
begin
  LPath := GetStringArg(AArguments, 'path');
  LPattern := GetStringArg(AArguments, 'pattern');
  LDirectory := GetStringArg(AArguments, 'directory');
  LEncodingName := GetStringArg(AArguments, 'encoding');
  LRemove := GetBoolArg(AArguments, 'remove');
  if (LPath = '') and (LPattern = '') then
    raise EArgumentException.Create('Provide either "path" or "pattern"');
  if (LPath <> '') and (LPattern <> '') then
    raise EArgumentException.Create('Provide either "path" or "pattern", not both');
  if (LPath <> '') and (LDirectory <> '') then
    raise EArgumentException.Create('"directory" only applies to "pattern"');
  if LRemove then
  begin
    if LEncodingName <> '' then
      raise EArgumentException.Create('Do not pass "encoding" together with "remove"');
  end
  else
  begin
    if LEncodingName = '' then
      raise EArgumentException.Create('Missing required argument "encoding"');
    if EncodingIdFromName(LEncodingName) = TEncodingId.Unknown then
      raise EArgumentException.CreateFmt('Unsupported encoding: %s', [LEncodingName]);
  end;

  if LPath <> '' then
    Result := ExecuteForPath(LPath, LEncodingName, LRemove)
  else
    Result := ExecuteForPattern(LPattern, LDirectory, LEncodingName, LRemove);
end;

function TSetOverrideTool.ExecuteForPath(const APath, AEncodingName: string;
  ARemove: Boolean): TJSONObject;
var
  LCache: TEncodingCache;
  LRelative: string;
  LEntry: TCacheEntry;
  LJson: TJSONObject;
begin
  ValidatePathInWorkspace(APath);
  FCacheManager.Resolve(APath, LCache, LRelative);
  if ARemove then
  begin
    if not (LCache.TryGet(LRelative, LEntry) and LEntry.Manual) then
      raise EOverrideNotFound.CreateFmt('No per-file override is set for "%s" (sidecar %s)',
        [APath, LCache.CachePath]);
    // Drop the whole entry so the file is detected afresh on the next read
    LCache.Remove(LRelative);
  end
  else
  begin
    if not LCache.TryGet(LRelative, LEntry) then
      LEntry := Default(TCacheEntry);
    LEntry.EncodingId := EncodingIdFromName(AEncodingName);
    LEntry.Manual := True;
    LEntry.DetectedAt := Now;
    LCache.Put(LRelative, LEntry);
  end;
  LCache.Save;

  LJson := TJSONObject.Create;
  try
    if ARemove then
      LJson.AddPair('action', 'removed')
    else
      LJson.AddPair('action', 'set');
    LJson.AddPair('scope', 'file');
    LJson.AddPair('applied', 'path:' + LRelative);
    LJson.AddPair('path', APath);
    LJson.AddPair('sidecar', LCache.CachePath);
    if not ARemove then
      LJson.AddPair('encoding', EncodingIdName(EncodingIdFromName(AEncodingName)));
  except
    LJson.Free;
    raise;
  end;
  Result := BuildJsonTextResult(LJson, False);
end;

function TSetOverrideTool.ExecuteForPattern(const APattern, ADirectory,
  AEncodingName: string; ARemove: Boolean): TJSONObject;
var
  LPattern, LDirectory: string;
  LEncoding, LOtherId: TEncodingId;
  LChain: TArray<TEncodingCache>;
  LOuter: TEncodingCache;
  LRemovedFrom, LWarnings: TList<string>;
  LSearched: string;
  LJson: TJSONObject;
  LArray: TJSONArray;
  LItem: string;
  I: Integer;
begin
  LPattern := TEncodingCache.NormalizePattern(APattern);
  if ADirectory = '' then
    LDirectory := PrimaryWorkspaceRoot
  else
  begin
    ValidatePathInWorkspace(ADirectory);
    if not TDirectory.Exists(ADirectory) then
      raise EArgumentException.CreateFmt('"directory" is not an existing directory: %s',
        [ADirectory]);
    LDirectory := ADirectory;
  end;
  LChain := FCacheManager.GetChain(LDirectory);
  LOuter := LChain[High(LChain)];
  LEncoding := EncodingIdFromName(AEncodingName);

  LRemovedFrom := TList<string>.Create;
  LWarnings := TList<string>.Create;
  try
    if ARemove then
    begin
      LSearched := '';
      for I := 0 to High(LChain) do
      begin
        if LSearched <> '' then
          LSearched := LSearched + '; ';
        LSearched := LSearched + LChain[I].CachePath;
        if LChain[I].RemovePatternOverride(LPattern) then
        begin
          LChain[I].Save;
          LRemovedFrom.Add(LChain[I].CachePath);
        end;
      end;
      if LRemovedFrom.Count = 0 then
        raise EOverrideNotFound.CreateFmt('No override for pattern "%s" was found in: %s',
          [LPattern, LSearched]);
    end
    else
    begin
      LOuter.SetPatternOverride(LPattern, LEncoding);
      LOuter.Save;
      for I := 0 to High(LChain) - 1 do
        if LChain[I].TryGetOwnPatternOverride(LPattern, LOtherId) and (LOtherId <> LEncoding) then
          LWarnings.Add(Format(
            'The nearer sidecar %s maps the same pattern to %s and takes precedence ' +
            'for files below %s.',
            [LChain[I].CachePath, EncodingIdName(LOtherId), LChain[I].WorkspaceRoot]));
    end;

    LJson := TJSONObject.Create;
    try
      LJson.AddPair('scope', 'pattern');
      LJson.AddPair('pattern', LPattern);
      if ARemove then
      begin
        LJson.AddPair('action', 'removed');
        LJson.AddPair('applied', 'removed pattern:' + LPattern);
        LArray := TJSONArray.Create;
        LJson.AddPair('removedFrom', LArray);
        for LItem in LRemovedFrom do
          LArray.Add(LItem);
      end
      else
      begin
        LJson.AddPair('action', 'set');
        LJson.AddPair('applied', 'pattern:' + LPattern + ' (sidecar ' + LOuter.CachePath + ')');
        LJson.AddPair('encoding', EncodingIdName(LEncoding));
        LJson.AddPair('sidecar', LOuter.CachePath);
        LJson.AddPair('root', LOuter.WorkspaceRoot);
        if LPattern.Contains('/') then
          LJson.AddPair('matches', 'path relative to ' + LOuter.WorkspaceRoot)
        else
          LJson.AddPair('matches', 'file name');
        LJson.AddPair('appliesTo', Format(
          'All matching files below %s, including subfolders with their own project ' +
          'files, unless a nearer sidecar defines a matching override.',
          [LOuter.WorkspaceRoot]));
      end;
      if LWarnings.Count > 0 then
      begin
        LArray := TJSONArray.Create;
        LJson.AddPair('warnings', LArray);
        for LItem in LWarnings do
          LArray.Add(LItem);
      end;
    except
      LJson.Free;
      raise;
    end;
  finally
    LWarnings.Free;
    LRemovedFrom.Free;
  end;
  Result := BuildJsonTextResult(LJson, False);
end;

end.
