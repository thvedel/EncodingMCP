unit Tools.BatchWrite;

/// <summary>
///   MCP tool: write_text_files. Writes multiple files in a single call,
///   each with individual encoding/lineEnding/hasBom options.
///   Errors for individual files are reported inline without aborting the batch.
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  MCP.Tools,
  Encoding.CacheManager;

type
  TBatchWriteTool = class(TInterfacedObject, IMcpTool)
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
  Encoding.Workspace,
  FileIO.Writer;

{ TBatchWriteTool }

constructor TBatchWriteTool.Create(ACacheManager: TCacheManager);
begin
  inherited Create;
  FCacheManager := ACacheManager;
end;

function TBatchWriteTool.GetName: string;
begin
  Result := 'write_text_files';
end;

function TBatchWriteTool.GetDescription: string;
begin
  Result :=
    'Write multiple text files in a single call with encoding-aware conversion. ' +
    'Each file entry can specify its own encoding, lineEnding, and hasBom options. ' +
    'Errors for individual files are reported inline without aborting the batch. ' +
    'Use this for scaffolding or code generation where multiple files are created at once.';
end;

function TBatchWriteTool.BuildInputSchema: TJSONObject;
var
  LProps, LFiles, LFileItems, LFileProps: TJSONObject;
  LPathProp, LContentProp, LEncProp, LLineProp, LBomProp, LCreateProp: TJSONObject;
  LEncEnum, LLineEnum: TJSONArray;
  LRequired, LFileRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('type', 'object');
    LProps := TJSONObject.Create;

    LFiles := TJSONObject.Create;
    LFiles.AddPair('type', 'array');
    LFiles.AddPair('description',
      'Array of file specifications to write. Each entry specifies path, content, ' +
      'and optional encoding/lineEnding/hasBom/createIfMissing.');

    LFileItems := TJSONObject.Create;
    LFileItems.AddPair('type', 'object');
    LFileProps := TJSONObject.Create;

    LPathProp := TJSONObject.Create;
    LPathProp.AddPair('type', 'string');
    LPathProp.AddPair('description', 'Absolute path to the file to write.');
    LFileProps.AddPair('path', LPathProp);

    LContentProp := TJSONObject.Create;
    LContentProp.AddPair('type', 'string');
    LContentProp.AddPair('description', 'UTF-8 content to write.');
    LFileProps.AddPair('content', LContentProp);

    LEncProp := TJSONObject.Create;
    LEncProp.AddPair('type', 'string');
    LEncProp.AddPair('description',
      'Optional: target encoding. If omitted, preserves existing.');
    LEncEnum := TJSONArray.Create;
    LEncEnum.Add('UTF-8');
    LEncEnum.Add('UTF-16LE');
    LEncEnum.Add('UTF-16BE');
    LEncEnum.Add('Windows-1252');
    LEncEnum.Add('ISO-8859-1');
    LEncEnum.Add('ISO-8859-15');
    LEncEnum.Add('ASCII');
    LEncProp.AddPair('enum', LEncEnum);
    LFileProps.AddPair('encoding', LEncProp);

    LLineProp := TJSONObject.Create;
    LLineProp.AddPair('type', 'string');
    LLineProp.AddPair('description',
      'Optional: line-ending style. Default preserves existing.');
    LLineEnum := TJSONArray.Create;
    LLineEnum.Add('CRLF');
    LLineEnum.Add('LF');
    LLineEnum.Add('CR');
    LLineProp.AddPair('enum', LLineEnum);
    LFileProps.AddPair('lineEnding', LLineProp);

    LBomProp := TJSONObject.Create;
    LBomProp.AddPair('type', 'boolean');
    LBomProp.AddPair('description',
      'Optional: write a BOM. Default preserves existing or true for new UTF files.');
    LFileProps.AddPair('hasBom', LBomProp);

    LCreateProp := TJSONObject.Create;
    LCreateProp.AddPair('type', 'boolean');
    LCreateProp.AddPair('description',
      'Optional (default true): create the file if it does not exist.');
    LFileProps.AddPair('createIfMissing', LCreateProp);

    LFileRequired := TJSONArray.Create;
    LFileRequired.Add('path');
    LFileRequired.Add('content');
    LFileItems.AddPair('properties', LFileProps);
    LFileItems.AddPair('required', LFileRequired);

    LFiles.AddPair('items', LFileItems);
    LFiles.AddPair('minItems', TJSONNumber.Create(1));
    LProps.AddPair('files', LFiles);

    Result.AddPair('properties', LProps);
    LRequired := TJSONArray.Create;
    LRequired.Add('files');
    Result.AddPair('required', LRequired);
  except
    Result.Free;
    raise;
  end;
end;

function GetStringArg(AObj: TJSONObject; const AName: string;
  const ADefault: string = ''): string;
var
  LValue: TJSONValue;
begin
  if AObj = nil then Exit(ADefault);
  LValue := AObj.GetValue(AName);
  if LValue is TJSONString then
    Result := TJSONString(LValue).Value
  else
    Result := ADefault;
end;

function GetBoolArg(AObj: TJSONObject; const AName: string;
  ADefault: Boolean): Boolean;
var
  LValue: TJSONValue;
begin
  if AObj = nil then Exit(ADefault);
  LValue := AObj.GetValue(AName);
  if LValue is TJSONBool then
    Result := TJSONBool(LValue).AsBoolean
  else
    Result := ADefault;
end;

function HasArg(AObj: TJSONObject; const AName: string): Boolean;
begin
  Result := (AObj <> nil) and (AObj.GetValue(AName) <> nil);
end;

function BuildFileResult(const APath: string; const AResult: TWriteResult): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('path', APath);
    Result.AddPair('encoding', EncodingIdName(AResult.EncodingId));
    Result.AddPair('hasBom', TJSONBool.Create(AResult.HasBom));
    Result.AddPair('lineEnding', LineEndingName(AResult.LineEnding));
    Result.AddPair('bytesWritten', TJSONNumber.Create(AResult.BytesWritten));
    Result.AddPair('created', TJSONBool.Create(AResult.Created));
  except
    Result.Free;
    raise;
  end;
end;

function BuildFileError(const APath, AError: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('path', APath);
    Result.AddPair('error', AError);
  except
    Result.Free;
    raise;
  end;
end;

function TBatchWriteTool.Execute(AArguments: TJSONObject): TJSONObject;
var
  LFilesArr: TJSONArray;
  LFileObj: TJSONObject;
  LResultsArr: TJSONArray;
  LOuterJson: TJSONObject;
  LPath, LContent, LEncodingName, LLineEndingName: string;
  LOptions: TWriteOptions;
  LWriteResult: TWriteResult;
  LErrorCount: Integer;
  I: Integer;
begin
  if AArguments = nil then
    raise Exception.Create('Missing required argument "files"');

  LFilesArr := AArguments.GetValue('files') as TJSONArray;
  if (LFilesArr = nil) or (LFilesArr.Count = 0) then
    raise Exception.Create('Missing or empty required argument "files"');

  LErrorCount := 0;
  LResultsArr := TJSONArray.Create;
  try
    for I := 0 to LFilesArr.Count - 1 do
    begin
      LFileObj := LFilesArr.Items[I] as TJSONObject;
      LPath := GetStringArg(LFileObj, 'path');

      if LPath = '' then
      begin
        LResultsArr.AddElement(BuildFileError('', 'Missing required argument "path"'));
        Inc(LErrorCount);
        Continue;
      end;

      try
        ValidatePathInWorkspace(LPath);

        LContent := GetStringArg(LFileObj, 'content');
        LOptions := MakeDefaultWriteOptions;

        LEncodingName := GetStringArg(LFileObj, 'encoding');
        if LEncodingName <> '' then
        begin
          LOptions.EncodingOverride := EncodingIdFromName(LEncodingName);
          if LOptions.EncodingOverride = TEncodingId.Unknown then
            raise Exception.CreateFmt('Unsupported encoding: %s', [LEncodingName]);
        end;

        LLineEndingName := GetStringArg(LFileObj, 'lineEnding');
        if LLineEndingName <> '' then
          LOptions.LineEndingOverride := LineEndingFromName(LLineEndingName);

        if HasArg(LFileObj, 'hasBom') then
        begin
          if GetBoolArg(LFileObj, 'hasBom', False) then
            LOptions.HasBomOverride := 1
          else
            LOptions.HasBomOverride := 0;
        end;

        LOptions.CreateIfMissing := GetBoolArg(LFileObj, 'createIfMissing', True);

        LWriteResult := WriteTextFile(LPath, LContent, FCacheManager, LOptions);
        LResultsArr.AddElement(BuildFileResult(LPath, LWriteResult));
      except
        on E: Exception do
        begin
          LResultsArr.AddElement(BuildFileError(LPath, E.Message));
          Inc(LErrorCount);
        end;
      end;
    end;

    LOuterJson := TJSONObject.Create;
    try
      LOuterJson.AddPair('totalFiles', TJSONNumber.Create(LFilesArr.Count));
      LOuterJson.AddPair('succeeded', TJSONNumber.Create(LFilesArr.Count - LErrorCount));
      LOuterJson.AddPair('failed', TJSONNumber.Create(LErrorCount));
      LOuterJson.AddPair('results', LResultsArr);
    except
      LOuterJson.Free;
      raise;
    end;
  except
    LResultsArr.Free;
    raise;
  end;

  Result := BuildJsonTextResult(LOuterJson, LErrorCount > 0);
end;

end.
