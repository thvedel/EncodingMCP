unit Tools.ReadFile;

/// <summary>
///   MCP tool: read_text_file. Reads a text file with automatic encoding detection
///   and returns the content as UTF-8 along with encoding metadata.
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  MCP.Tools,
  Encoding.CacheManager;

type
  TReadFileTool = class(TInterfacedObject, IMcpTool)
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
  Encoding.Types,
  Encoding.Workspace,
  FileIO.Reader;

{ TReadFileTool }

constructor TReadFileTool.Create(ACacheManager: TCacheManager);
begin
  inherited Create;
  FCacheManager := ACacheManager;
end;

function TReadFileTool.GetName: string;
begin
  Result := 'read_text_file';
end;

function TReadFileTool.GetDescription: string;
begin
  Result :=
    'Read a text file with automatic encoding detection (BOM, UTF-8, Windows-1252, ' +
    'ISO-8859-1/15, UTF-16). Returns content as UTF-8 plus the detected encoding ' +
    'and line-ending style. Use this instead of generic file reads when working ' +
    'with files that may not be UTF-8 (e.g. Delphi .pas/.dfm sources).';
end;

function TReadFileTool.BuildInputSchema: TJSONObject;
var
  LProps, LPath, LHead, LTail, LStartLine, LEndLine: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('type', 'object');
    LProps := TJSONObject.Create;
    LPath := TJSONObject.Create;
    LPath.AddPair('type', 'string');
    LPath.AddPair('description', 'Absolute path to the file to read.');
    LProps.AddPair('path', LPath);
    LHead := TJSONObject.Create;
    LHead.AddPair('type', 'integer');
    LHead.AddPair('description', 'Optional: only return the first N lines.');
    LHead.AddPair('minimum', TJSONNumber.Create(1));
    LProps.AddPair('head', LHead);
    LTail := TJSONObject.Create;
    LTail.AddPair('type', 'integer');
    LTail.AddPair('description', 'Optional: only return the last N lines.');
    LTail.AddPair('minimum', TJSONNumber.Create(1));
    LProps.AddPair('tail', LTail);
    LStartLine := TJSONObject.Create;
    LStartLine.AddPair('type', 'integer');
    LStartLine.AddPair('description',
      'Optional: 1-based line number to start reading from. ' +
      'Use together with endLine to read a specific line range. ' +
      'Takes priority over head/tail when specified.');
    LStartLine.AddPair('minimum', TJSONNumber.Create(1));
    LProps.AddPair('startLine', LStartLine);
    LEndLine := TJSONObject.Create;
    LEndLine.AddPair('type', 'integer');
    LEndLine.AddPair('description',
      'Optional: 1-based line number to stop reading at (inclusive). ' +
      'Use together with startLine to read a specific line range. ' +
      'Takes priority over head/tail when specified.');
    LEndLine.AddPair('minimum', TJSONNumber.Create(1));
    LProps.AddPair('endLine', LEndLine);
    var LContextLines := TJSONObject.Create;
    LContextLines.AddPair('type', 'integer');
    LContextLines.AddPair('description',
      'Optional: number of extra lines to include before and after the ' +
      'startLine/endLine range or each search match for additional context. ' +
      'Applies when startLine/endLine or searchText is specified.');
    LContextLines.AddPair('minimum', TJSONNumber.Create(0));
    LProps.AddPair('contextLines', LContextLines);
    var LMetadataOnly := TJSONObject.Create;
    LMetadataOnly.AddPair('type', 'boolean');
    LMetadataOnly.AddPair('description',
      'Optional: if true, return only metadata (encoding, lineEnding, ' +
      'totalLines, etc.) without file content. Useful for checking file ' +
      'properties without transferring the full text.');
    LProps.AddPair('metadataOnly', LMetadataOnly);
    var LSearchText := TJSONObject.Create;
    LSearchText.AddPair('type', 'string');
    LSearchText.AddPair('description',
      'Optional: search for lines containing this text (case-insensitive). ' +
      'Returns only matching lines with line-number prefixes. ' +
      'Non-contiguous regions are separated by "...". ' +
      'Use contextLines to include surrounding lines. ' +
      'Takes priority over head/tail/startLine/endLine.');
    LProps.AddPair('searchText', LSearchText);
    Result.AddPair('properties', LProps);
    LRequired := TJSONArray.Create;
    LRequired.Add('path');
    Result.AddPair('required', LRequired);
  except
    Result.Free;
    raise;
  end;
end;

function GetStringArg(AArgs: TJSONObject; const AName: string;
  const ADefault: string = ''): string;
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

function GetIntArg(AArgs: TJSONObject; const AName: string; ADefault: Integer = 0): Integer;
var
  LValue: TJSONValue;
begin
  if AArgs = nil then Exit(ADefault);
  LValue := AArgs.GetValue(AName);
  if LValue is TJSONNumber then
    Result := TJSONNumber(LValue).AsInt
  else
    Result := ADefault;
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

function TReadFileTool.Execute(AArguments: TJSONObject): TJSONObject;
var
  LPath: string;
  LHead, LTail, LStartLine, LEndLine, LContextLines: Integer;
  LMetadataOnly: Boolean;
  LSearchText: string;
  LResult: TReadResult;
  LJson: TJSONObject;
begin
  LPath := GetStringArg(AArguments, 'path');
  if LPath = '' then
    raise Exception.Create('Missing required argument "path"');
  ValidatePathInWorkspace(LPath);
  LHead := GetIntArg(AArguments, 'head', 0);
  LTail := GetIntArg(AArguments, 'tail', 0);
  LStartLine := GetIntArg(AArguments, 'startLine', 0);
  LEndLine := GetIntArg(AArguments, 'endLine', 0);
  LContextLines := GetIntArg(AArguments, 'contextLines', 0);
  LMetadataOnly := GetBoolArg(AArguments, 'metadataOnly', False);
  LSearchText := GetStringArg(AArguments, 'searchText');
  LResult := ReadTextFile(LPath, FCacheManager, LHead, LTail, LStartLine, LEndLine,
    LContextLines, LSearchText);
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('path', LPath);
    LJson.AddPair('encoding', EncodingIdName(LResult.EncodingId));
    LJson.AddPair('hasBom', TJSONBool.Create(LResult.HasBom));
    LJson.AddPair('lineEnding', LineEndingName(LResult.LineEnding));
    LJson.AddPair('confidence', TJSONNumber.Create(LResult.Confidence));
    LJson.AddPair('fromCache', TJSONBool.Create(LResult.FromCache));
    LJson.AddPair('bytesRead', TJSONNumber.Create(LResult.BytesRead));
    LJson.AddPair('totalLines', TJSONNumber.Create(LResult.TotalLines));
    LJson.AddPair('returnedLines', TJSONNumber.Create(LResult.ReturnedLines));
    LJson.AddPair('lineNumberStart', TJSONNumber.Create(LResult.LineNumberStart));
    if LResult.MatchCount > 0 then
      LJson.AddPair('matchCount', TJSONNumber.Create(LResult.MatchCount));
    if not LMetadataOnly then
      LJson.AddPair('content', LResult.Content);
  except
    LJson.Free;
    raise;
  end;
  Result := BuildJsonTextResult(LJson, False);
end;

end.
