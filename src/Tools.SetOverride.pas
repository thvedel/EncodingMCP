unit Tools.SetOverride;

/// <summary>
///   MCP-tool: set_encoding_override. Sætter en manuel encoding-override for
///   en specifik fil eller for et extension-pattern (fx *.pas → Windows-1252).
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  MCP.Tools,
  Encoding.CacheManager;

type
  TSetOverrideTool = class(TInterfacedObject, IMcpTool)
  strict private
    FCacheManager: TCacheManager;
  public
    constructor Create(ACacheManager: TCacheManager);
    function GetName: string;
    function GetDescription: string;
    function BuildInputSchema: TJSONObject;
    function Execute(AArguments: TJSONObject): TJSONObject;
  end;

implementation

uses
  System.DateUtils,
  Encoding.Types,
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
    'Manually set the encoding for a specific file (path) or for all files ' +
    'matching an extension pattern (pattern, e.g. "*.pas"). Overrides take ' +
    'precedence over auto-detection except when a BOM is present.';
end;

function TSetOverrideTool.BuildInputSchema: TJSONObject;
var
  LProps, LPath, LPattern, LEnc: TJSONObject;
  LRequired, LEncEnum: TJSONArray;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('type', 'object');
    LProps := TJSONObject.Create;
    LPath := TJSONObject.Create;
    LPath.AddPair('type', 'string');
    LPath.AddPair('description',
      'Absolute path of a single file (provide either path OR pattern).');
    LProps.AddPair('path', LPath);
    LPattern := TJSONObject.Create;
    LPattern.AddPair('type', 'string');
    LPattern.AddPair('description',
      'Extension pattern (e.g. "*.pas") - applies to all matching files in the workspace.');
    LProps.AddPair('pattern', LPattern);
    LEnc := TJSONObject.Create;
    LEnc.AddPair('type', 'string');
    LEnc.AddPair('description', 'The encoding to force.');
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
    Result.AddPair('properties', LProps);
    LRequired := TJSONArray.Create;
    LRequired.Add('encoding');
    Result.AddPair('required', LRequired);
  except
    Result.Free;
    raise;
  end;
end;

function GetStringArg(AArgs: TJSONObject; const AName: string): string;
var
  LValue: TJSONValue;
begin
  Result := '';
  if AArgs = nil then Exit;
  LValue := AArgs.GetValue(AName);
  if LValue is TJSONString then
    Result := TJSONString(LValue).Value;
end;

function TSetOverrideTool.Execute(AArguments: TJSONObject): TJSONObject;
var
  LPath, LPattern, LEncodingName: string;
  LEncoding: TEncodingId;
  LCache: TEncodingCache;
  LRelative: string;
  LEntry: TCacheEntry;
  LJson: TJSONObject;
  LApplied: string;
begin
  LPath := GetStringArg(AArguments, 'path');
  LPattern := GetStringArg(AArguments, 'pattern');
  LEncodingName := GetStringArg(AArguments, 'encoding');
  if LEncodingName = '' then
    raise Exception.Create('Missing required argument "encoding"');
  LEncoding := EncodingIdFromName(LEncodingName);
  if LEncoding = TEncodingId.Unknown then
    raise Exception.CreateFmt('Unsupported encoding: %s', [LEncodingName]);
  if (LPath = '') and (LPattern = '') then
    raise Exception.Create('Provide either "path" or "pattern"');
  if (LPath <> '') and (LPattern <> '') then
    raise Exception.Create('Provide either "path" or "pattern", not both');

  if LPath <> '' then
  begin
    FCacheManager.Resolve(LPath, LCache, LRelative);
    LEntry := Default(TCacheEntry);
    if not LCache.TryGet(LRelative, LEntry) then
      LEntry := Default(TCacheEntry);
    LEntry.EncodingId := LEncoding;
    LEntry.Manual := True;
    LEntry.DetectedAt := Now;
    LCache.Put(LRelative, LEntry);
    LApplied := 'path:' + LRelative;
  end
  else
  begin
    // Pattern - vælg cache for nuværende arbejdsmappe
    FCacheManager.Resolve(GetCurrentDir, LCache, LRelative);
    LCache.SetExtensionOverride(LPattern, LEncoding);
    LApplied := 'pattern:' + LPattern + ' (workspace ' + LCache.WorkspaceRoot + ')';
  end;
  LCache.Save;

  LJson := TJSONObject.Create;
  try
    LJson.AddPair('applied', LApplied);
    LJson.AddPair('encoding', EncodingIdName(LEncoding));
  except
    LJson.Free;
    raise;
  end;
  Result := BuildJsonTextResult(LJson, False);
end;

end.
