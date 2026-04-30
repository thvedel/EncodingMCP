unit Tools.WriteFile;

/// <summary>
///   MCP-tool: write_text_file. Skriver UTF-8 indhold til en tekstfil i den
///   korrekte encoding (cachet, override eller detekteret fra eksisterende fil).
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  MCP.Tools,
  Encoding.CacheManager;

type
  TWriteFileTool = class(TInterfacedObject, IMcpTool)
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
  Encoding.Types,
  FileIO.Writer;

{ TWriteFileTool }

constructor TWriteFileTool.Create(ACacheManager: TCacheManager);
begin
  inherited Create;
  FCacheManager := ACacheManager;
end;

function TWriteFileTool.GetName: string;
begin
  Result := 'write_text_file';
end;

function TWriteFileTool.GetDescription: string;
begin
  Result :=
    'Write UTF-8 content to a text file, automatically converting to the file''s ' +
    'original encoding. If the file does not exist, defaults to UTF-8 with BOM. ' +
    'Always use this tool when writing to source files that may be Windows-1252 ' +
    'encoded (e.g. Delphi .pas/.dfm) to avoid corrupting non-ASCII characters.';
end;

function MakeStringProp(const AType, ADescription: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', AType);
  Result.AddPair('description', ADescription);
end;

function TWriteFileTool.BuildInputSchema: TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
  LEnc, LLineEnding: TJSONObject;
  LEncEnum, LLineEnum: TJSONArray;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('type', 'object');
    LProps := TJSONObject.Create;
    LProps.AddPair('path', MakeStringProp('string', 'Absolute path to the file to write.'));
    LProps.AddPair('content', MakeStringProp('string', 'UTF-8 content to write.'));
    LEnc := TJSONObject.Create;
    LEnc.AddPair('type', 'string');
    LEnc.AddPair('description',
      'Optional: target encoding. If omitted, the file''s existing encoding is preserved.');
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
    LLineEnding := TJSONObject.Create;
    LLineEnding.AddPair('type', 'string');
    LLineEnding.AddPair('description',
      'Optional: line-ending style (CRLF/LF/CR). Default preserves existing.');
    LLineEnum := TJSONArray.Create;
    LLineEnum.Add('CRLF');
    LLineEnum.Add('LF');
    LLineEnum.Add('CR');
    LLineEnding.AddPair('enum', LLineEnum);
    LProps.AddPair('lineEnding', LLineEnding);
    LProps.AddPair('hasBom', MakeStringProp('boolean',
      'Optional: write a BOM. Default preserves existing or true for new UTF files.'));
    LProps.AddPair('createIfMissing', MakeStringProp('boolean',
      'Optional (default true): create the file if it does not exist.'));
    Result.AddPair('properties', LProps);
    LRequired := TJSONArray.Create;
    LRequired.Add('path');
    LRequired.Add('content');
    Result.AddPair('required', LRequired);
  except
    Result.Free;
    raise;
  end;
end;

function GetStringArg(AArgs: TJSONObject; const AName, ADefault: string): string;
var
  LValue: TJSONValue;
begin
  if AArgs = nil then Exit(ADefault);
  LValue := AArgs.GetValue(AName);
  if LValue is TJSONString then
    Result := TJSONString(LValue).Value
  else
    Result := ADefault;
end;

function HasArg(AArgs: TJSONObject; const AName: string): Boolean;
begin
  Result := (AArgs <> nil) and (AArgs.GetValue(AName) <> nil);
end;

function GetBoolArg(AArgs: TJSONObject; const AName: string; ADefault: Boolean): Boolean;
var
  LValue: TJSONValue;
begin
  if AArgs = nil then Exit(ADefault);
  LValue := AArgs.GetValue(AName);
  if LValue is TJSONBool then
    Result := TJSONBool(LValue).AsBoolean
  else
    Result := ADefault;
end;

function TWriteFileTool.Execute(AArguments: TJSONObject): TJSONObject;
var
  LPath, LContent, LEncodingName, LLineEndingName: string;
  LOptions: TWriteOptions;
  LWriteResult: TWriteResult;
  LJson: TJSONObject;
begin
  LPath := GetStringArg(AArguments, 'path', '');
  if LPath = '' then
    raise Exception.Create('Missing required argument "path"');
  LContent := GetStringArg(AArguments, 'content', '');
  LOptions := MakeDefaultWriteOptions;
  LEncodingName := GetStringArg(AArguments, 'encoding', '');
  if LEncodingName <> '' then
  begin
    LOptions.EncodingOverride := EncodingIdFromName(LEncodingName);
    if LOptions.EncodingOverride = TEncodingId.Unknown then
      raise Exception.CreateFmt('Unsupported encoding: %s', [LEncodingName]);
  end;
  LLineEndingName := GetStringArg(AArguments, 'lineEnding', '');
  if LLineEndingName <> '' then
    LOptions.LineEndingOverride := LineEndingFromName(LLineEndingName);
  if HasArg(AArguments, 'hasBom') then
  begin
    if GetBoolArg(AArguments, 'hasBom', False) then
      LOptions.HasBomOverride := 1
    else
      LOptions.HasBomOverride := 0;
  end;
  LOptions.CreateIfMissing := GetBoolArg(AArguments, 'createIfMissing', True);

  LWriteResult := WriteTextFile(LPath, LContent, FCacheManager, LOptions);
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('path', LPath);
    LJson.AddPair('encoding', EncodingIdName(LWriteResult.EncodingId));
    LJson.AddPair('hasBom', TJSONBool.Create(LWriteResult.HasBom));
    LJson.AddPair('lineEnding', LineEndingName(LWriteResult.LineEnding));
    LJson.AddPair('bytesWritten', TJSONNumber.Create(LWriteResult.BytesWritten));
    LJson.AddPair('created', TJSONBool.Create(LWriteResult.Created));
  except
    LJson.Free;
    raise;
  end;
  Result := BuildJsonTextResult(LJson, False);
end;

end.
