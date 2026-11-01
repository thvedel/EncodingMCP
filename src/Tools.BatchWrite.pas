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
  Encoding.Workspace,
  FileIO.Atomic,
  FileIO.Reader,
  FileIO.Writer,
  Tools.WriteFile;

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
    'Each file entry can specify its own encoding, lineEnding, hasBom, createIfMissing, ' +
    'dryRun and force options. ' +
    'Each result reports the encoding actually used, its source, any ASCII upgrade ' +
    '("upgradedFrom") and "warnings". ' +
    'Errors for individual files are reported inline without aborting the batch. ' +
    'Use this for scaffolding or code generation where multiple files are created at once.';
end;

function TBatchWriteTool.BuildInputSchema: TJSONObject;
var
  LProps, LFiles, LFileItems, LFileProps: TJSONObject;
  LPathProp, LContentProp: TJSONObject;
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
      'and optional encoding/lineEnding/hasBom/createIfMissing/dryRun/force.');

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

    AddWriteOptionProps(LFileProps);

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

function BuildFileResult(const APath: string; const AResult: TWriteResult;
  ADryRun: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('path', APath);
    AddWriteResultFields(Result, AResult, ADryRun);
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
  LPath, LContent: string;
  LOptions: TWriteOptions;
  LWriteResult: TWriteResult;
  LErrorCount: Integer;
  I: Integer;
begin
  if AArguments = nil then
    raise EInvalidArgumentError.Create('Missing required argument "files"');

  LFilesArr := AArguments.GetValue('files') as TJSONArray;
  if (LFilesArr = nil) or (LFilesArr.Count = 0) then
    raise EInvalidArgumentError.Create('Missing or empty required argument "files"');

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
        LOptions := ParseWriteOptions(LFileObj);

        LWriteResult := WriteTextFile(LPath, LContent, FCacheManager, LOptions);
        LResultsArr.AddElement(BuildFileResult(LPath, LWriteResult, LOptions.DryRun));
      except
        on E: EUnsupportedCharsError do
        begin
          LResultsArr.AddElement(BuildUnsupportedCharsJson(LPath, E));
          Inc(LErrorCount);
        end;
        on E: EBinaryDfmError do
        begin
          LResultsArr.AddElement(BuildFormatErrorJson(LPath, FORMAT_BINARY_DFM, E.Message));
          Inc(LErrorCount);
        end;
        on E: EFileLockedError do
        begin
          LResultsArr.AddElement(BuildConcurrencyErrorJson(LPath, 'locked', E.Message));
          Inc(LErrorCount);
        end;
        on E: EFileModifiedError do
        begin
          LResultsArr.AddElement(BuildConcurrencyErrorJson(LPath, 'modified', E.Message));
          Inc(LErrorCount);
        end;
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
