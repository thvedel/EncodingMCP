unit Tools.BatchRead;

/// <summary>
///   MCP tool: read_text_files. Reads multiple files in a single call,
///   returning encoding metadata and (optionally) content for each file.
///   Reduces MCP round-trips during cross-file refactoring.
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  MCP.Tools,
  Encoding.CacheManager;

type
  TBatchReadTool = class(TInterfacedObject, IMcpTool)
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
  System.IOUtils,
  System.Generics.Collections,
  Encoding.Types,
  Encoding.Workspace,
  FileIO.Reader;

{ TBatchReadTool }

constructor TBatchReadTool.Create(ACacheManager: TCacheManager);
begin
  inherited Create;
  FCacheManager := ACacheManager;
end;

function TBatchReadTool.GetName: string;
begin
  Result := 'read_text_files';
end;

function TBatchReadTool.GetDescription: string;
begin
  Result :=
    'Read multiple text files in a single call with automatic encoding detection. ' +
    'Returns an array of results, each containing encoding metadata and (optionally) content. ' +
    'Use this instead of multiple read_text_file calls to reduce round-trips. ' +
    'Errors for individual files are reported inline without aborting the batch.';
end;

function TBatchReadTool.BuildInputSchema: TJSONObject;
var
  LProps, LFiles, LFileItems, LFileProps: TJSONObject;
  LPathProp, LHeadProp, LTailProp, LStartLineProp, LEndLineProp: TJSONObject;
  LContextLinesProp, LMetadataOnlyProp, LSearchTextProp: TJSONObject;
  LRequired, LFileRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('type', 'object');
    LProps := TJSONObject.Create;

    // files: array of file specifications
    LFiles := TJSONObject.Create;
    LFiles.AddPair('type', 'array');
    LFiles.AddPair('description',
      'Array of file specifications to read. Each entry can specify ' +
      'its own head/tail/startLine/endLine/contextLines/metadataOnly/searchText.');

    LFileItems := TJSONObject.Create;
    LFileItems.AddPair('type', 'object');
    LFileProps := TJSONObject.Create;

    LPathProp := TJSONObject.Create;
    LPathProp.AddPair('type', 'string');
    LPathProp.AddPair('description', 'Absolute path to the file to read.');
    LFileProps.AddPair('path', LPathProp);

    LHeadProp := TJSONObject.Create;
    LHeadProp.AddPair('type', 'integer');
    LHeadProp.AddPair('description', 'Optional: only return the first N lines.');
    LHeadProp.AddPair('minimum', TJSONNumber.Create(1));
    LFileProps.AddPair('head', LHeadProp);

    LTailProp := TJSONObject.Create;
    LTailProp.AddPair('type', 'integer');
    LTailProp.AddPair('description', 'Optional: only return the last N lines.');
    LTailProp.AddPair('minimum', TJSONNumber.Create(1));
    LFileProps.AddPair('tail', LTailProp);

    LStartLineProp := TJSONObject.Create;
    LStartLineProp.AddPair('type', 'integer');
    LStartLineProp.AddPair('description',
      'Optional: 1-based line number to start reading from.');
    LStartLineProp.AddPair('minimum', TJSONNumber.Create(1));
    LFileProps.AddPair('startLine', LStartLineProp);

    LEndLineProp := TJSONObject.Create;
    LEndLineProp.AddPair('type', 'integer');
    LEndLineProp.AddPair('description',
      'Optional: 1-based line number to stop reading at (inclusive).');
    LEndLineProp.AddPair('minimum', TJSONNumber.Create(1));
    LFileProps.AddPair('endLine', LEndLineProp);

    LContextLinesProp := TJSONObject.Create;
    LContextLinesProp.AddPair('type', 'integer');
    LContextLinesProp.AddPair('description',
      'Optional: extra context lines before/after range or search matches.');
    LContextLinesProp.AddPair('minimum', TJSONNumber.Create(0));
    LFileProps.AddPair('contextLines', LContextLinesProp);

    LMetadataOnlyProp := TJSONObject.Create;
    LMetadataOnlyProp.AddPair('type', 'boolean');
    LMetadataOnlyProp.AddPair('description',
      'Optional: if true, return only metadata without file content.');
    LFileProps.AddPair('metadataOnly', LMetadataOnlyProp);

    LSearchTextProp := TJSONObject.Create;
    LSearchTextProp.AddPair('type', 'string');
    LSearchTextProp.AddPair('description',
      'Optional: search for lines containing this text (case-insensitive).');
    LFileProps.AddPair('searchText', LSearchTextProp);

    LFileRequired := TJSONArray.Create;
    LFileRequired.Add('path');
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

function GetIntArg(AObj: TJSONObject; const AName: string;
  ADefault: Integer = 0): Integer;
var
  LValue: TJSONValue;
begin
  if AObj = nil then Exit(ADefault);
  LValue := AObj.GetValue(AName);
  if LValue is TJSONNumber then
    Result := TJSONNumber(LValue).AsInt
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

/// <summary>
///   Builds the JSON result object for a single file read.
/// </summary>
function BuildFileResult(const APath: string; const AResult: TReadResult;
  AMetadataOnly: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('path', APath);
    Result.AddPair('encoding', EncodingIdName(AResult.EncodingId));
    Result.AddPair('hasBom', TJSONBool.Create(AResult.HasBom));
    Result.AddPair('lineEnding', LineEndingName(AResult.LineEnding));
    Result.AddPair('confidence', TJSONNumber.Create(AResult.Confidence));
    Result.AddPair('fromCache', TJSONBool.Create(AResult.FromCache));
    Result.AddPair('bytesRead', TJSONNumber.Create(AResult.BytesRead));
    Result.AddPair('totalLines', TJSONNumber.Create(AResult.TotalLines));
    Result.AddPair('returnedLines', TJSONNumber.Create(AResult.ReturnedLines));
    Result.AddPair('lineNumberStart', TJSONNumber.Create(AResult.LineNumberStart));
    if AResult.MatchCount > 0 then
      Result.AddPair('matchCount', TJSONNumber.Create(AResult.MatchCount));
    if not AMetadataOnly then
      Result.AddPair('content', AResult.Content);
  except
    Result.Free;
    raise;
  end;
end;

/// <summary>
///   Builds a JSON error object for a file that failed to read.
/// </summary>
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

function TBatchReadTool.Execute(AArguments: TJSONObject): TJSONObject;
var
  LFilesArr: TJSONArray;
  LFileObj: TJSONObject;
  LResultsArr: TJSONArray;
  LOuterJson: TJSONObject;
  LPath, LSearchText: string;
  LHead, LTail, LStartLine, LEndLine, LContextLines: Integer;
  LMetadataOnly: Boolean;
  LReadResult: TReadResult;
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

        LHead := GetIntArg(LFileObj, 'head', 0);
        LTail := GetIntArg(LFileObj, 'tail', 0);
        LStartLine := GetIntArg(LFileObj, 'startLine', 0);
        LEndLine := GetIntArg(LFileObj, 'endLine', 0);
        LContextLines := GetIntArg(LFileObj, 'contextLines', 0);
        LMetadataOnly := GetBoolArg(LFileObj, 'metadataOnly', False);
        LSearchText := GetStringArg(LFileObj, 'searchText');

        LReadResult := ReadTextFile(LPath, FCacheManager, LHead, LTail,
          LStartLine, LEndLine, LContextLines, LSearchText);
        LResultsArr.AddElement(BuildFileResult(LPath, LReadResult, LMetadataOnly));
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
