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
  Encoding.Types,
  Encoding.CacheManager,
  FileIO.Reader;

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

/// <summary>
///   Adds writeRecommendation and an explanatory note when the encoding is
///   ASCII, because ASCII cannot tell which ASCII-compatible encoding the file
///   is meant to have. Does nothing for other encodings.
/// </summary>
procedure AddAsciiAdvice(AJson: TJSONObject; AEncodingId: TEncodingId);

/// <summary>
///   Adds the read result fields shared by read_text_file and read_text_files.
/// </summary>
procedure AddReadResultFields(AJson: TJSONObject; const AResult: TReadResult;
  AMetadataOnly: Boolean);

implementation

uses
  System.IOUtils,
  Encoding.Workspace;

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
    'with files that may not be UTF-8 (e.g. Delphi .pas/.dfm sources). ' +
    '"source" tells where the encoding came from (bom, fileOverride, ' +
    'patternOverride, detected). For ASCII files "writeRecommendation" names ' +
    'the encoding non-ASCII content will be written in. Binary Delphi forms are ' +
    'rejected with "format": "binary-dfm".';
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

procedure AddAsciiAdvice(AJson: TJSONObject; AEncodingId: TEncodingId);
begin
  if AEncodingId <> TEncodingId.Ascii then
    Exit;
  AJson.AddPair('writeRecommendation', EncodingIdName(ASCII_WRITE_RECOMMENDATION));
  AJson.AddPair('note', ASCII_NOTE);
end;

procedure AddReadResultFields(AJson: TJSONObject; const AResult: TReadResult;
  AMetadataOnly: Boolean);
begin
  AJson.AddPair('encoding', EncodingIdName(AResult.EncodingId));
  AJson.AddPair('hasBom', TJSONBool.Create(AResult.HasBom));
  AJson.AddPair('lineEnding', LineEndingName(AResult.LineEnding));
  AJson.AddPair('confidence', TJSONNumber.Create(AResult.Confidence));
  AJson.AddPair('source', EncodingSourceName(AResult.Source));
  AJson.AddPair('format', FORMAT_TEXT);
  AddAsciiAdvice(AJson, AResult.EncodingId);
  AJson.AddPair('fromCache', TJSONBool.Create(AResult.FromCache));
  AJson.AddPair('bytesRead', TJSONNumber.Create(AResult.BytesRead));
  AJson.AddPair('totalLines', TJSONNumber.Create(AResult.TotalLines));
  AJson.AddPair('returnedLines', TJSONNumber.Create(AResult.ReturnedLines));
  AJson.AddPair('lineNumberStart', TJSONNumber.Create(AResult.LineNumberStart));
  if AResult.MatchCount > 0 then
    AJson.AddPair('matchCount', TJSONNumber.Create(AResult.MatchCount));
  if not AMetadataOnly then
    AJson.AddPair('content', AResult.Content);
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
    raise EInvalidArgumentError.Create('Missing required argument "path"');
  ValidatePathInWorkspace(LPath);
  LHead := GetIntArg(AArguments, 'head', 0);
  LTail := GetIntArg(AArguments, 'tail', 0);
  LStartLine := GetIntArg(AArguments, 'startLine', 0);
  LEndLine := GetIntArg(AArguments, 'endLine', 0);
  LContextLines := GetIntArg(AArguments, 'contextLines', 0);
  LMetadataOnly := GetBoolArg(AArguments, 'metadataOnly', False);
  LSearchText := GetStringArg(AArguments, 'searchText');
  try
    LResult := ReadTextFile(LPath, FCacheManager, LHead, LTail, LStartLine, LEndLine,
      LContextLines, LSearchText);
  except
    on E: EBinaryDfmError do
      Exit(BuildJsonTextResult(BuildFormatErrorJson(LPath, FORMAT_BINARY_DFM, E.Message), True));
  end;
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('path', LPath);
    AddReadResultFields(LJson, LResult, LMetadataOnly);
  except
    LJson.Free;
    raise;
  end;
  Result := BuildJsonTextResult(LJson, False);
end;

end.
