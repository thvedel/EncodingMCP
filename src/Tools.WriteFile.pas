unit Tools.WriteFile;

/// <summary>
///   MCP tool: write_text_file. Writes UTF-8 content to a text file in the
///   correct encoding (cached, overridden, or detected from existing file).
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  MCP.Tools,
  Encoding.Types,
  Encoding.CacheManager,
  FileIO.Writer;

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

/// <summary>
///   Parses the write options shared by write_text_file and write_text_files
///   (encoding, lineEnding, hasBom, createIfMissing, dryRun).
/// </summary>
/// <exception cref="Exception">On an unsupported encoding or line-ending name.</exception>
function ParseWriteOptions(AArgs: TJSONObject): TWriteOptions;

/// <summary>
///   Adds the write result fields to a JSON response object: the encoding that
///   was actually used, where it came from, any upgrade and any warnings.
/// </summary>
procedure AddWriteResultFields(AJson: TJSONObject; const AResult: TWriteResult;
  ADryRun: Boolean);

/// <summary>
///   Adds the optional upgradedFrom, warnings and dryRun fields shared by the
///   write and edit tools.
/// </summary>
procedure AddUpgradeAndWarningFields(AJson: TJSONObject;
  AUpgradedFrom: TEncodingId; const AWarnings: TArray<string>; ADryRun: Boolean);

/// <summary>
///   Builds the structured error for content that the target encoding cannot
///   represent. The caller takes ownership.
/// </summary>
function BuildUnsupportedCharsJson(const APath: string;
  AError: EUnsupportedCharsError): TJSONObject;

/// <summary>
///   Builds the structured error returned when a write could not proceed
///   because another process holds the file (reason "locked") or changed it
///   since it was read (reason "modified"). The caller takes ownership.
/// </summary>
function BuildConcurrencyErrorJson(const APath, AReason, AMessage: string): TJSONObject;

/// <summary>Adds the schema properties shared by the write tools.</summary>
procedure AddWriteOptionProps(AProps: TJSONObject);

implementation

uses
  Encoding.Workspace,
  FileIO.Atomic,
  FileIO.Reader;

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
    'original encoding. The existing file is always re-checked on disk, and ' +
    'per-file or pattern overrides apply. If the file does not exist, defaults to ' +
    'UTF-8 with BOM. A pure-ASCII file that receives non-ASCII characters is ' +
    'written as Windows-1252 and reported via "upgradedFrom" and "warnings". ' +
    'Characters the target encoding cannot represent are rejected ' +
    '("unrepresentableChars"); nothing is written. An existing binary Delphi ' +
    'form ("format": "binary-dfm") is never overwritten unless force is true. ' +
    'Always use this tool when writing to source files that may be Windows-1252 ' +
    'encoded (e.g. Delphi .pas/.dfm) to avoid corrupting non-ASCII characters.';
end;

procedure AddWriteOptionProps(AProps: TJSONObject);
var
  LEnc, LLineEnding: TJSONObject;
  LEncEnum, LLineEnum: TJSONArray;
begin
  LEnc := TJSONObject.Create;
  LEnc.AddPair('type', 'string');
  LEnc.AddPair('description',
    'Optional: target encoding. If omitted, the file''s existing encoding is ' +
    'preserved. Changing only the encoding keeps the existing line endings; the ' +
    'BOM is kept, added when switching from an 8-bit encoding to Unicode, and ' +
    'dropped for 8-bit encodings.');
  LEncEnum := TJSONArray.Create;
  LEncEnum.Add('UTF-8');
  LEncEnum.Add('UTF-16LE');
  LEncEnum.Add('UTF-16BE');
  LEncEnum.Add('Windows-1252');
  LEncEnum.Add('ISO-8859-1');
  LEncEnum.Add('ISO-8859-15');
  LEncEnum.Add('ASCII');
  LEnc.AddPair('enum', LEncEnum);
  AProps.AddPair('encoding', LEnc);
  LLineEnding := TJSONObject.Create;
  LLineEnding.AddPair('type', 'string');
  LLineEnding.AddPair('description',
    'Optional: line-ending style (CRLF/LF/CR). Default preserves existing.');
  LLineEnum := TJSONArray.Create;
  LLineEnum.Add('CRLF');
  LLineEnum.Add('LF');
  LLineEnum.Add('CR');
  LLineEnding.AddPair('enum', LLineEnum);
  AProps.AddPair('lineEnding', LLineEnding);
  AProps.AddPair('hasBom', MakeProp('boolean',
    'Optional: write a BOM. Default preserves existing or true for new UTF files. ' +
    'hasBom true on an ASCII file writes UTF-8 with BOM.'));
  AProps.AddPair('createIfMissing', MakeProp('boolean',
    'Optional (default true): create the file if it does not exist.'));
  AProps.AddPair('dryRun', MakeProp('boolean',
    'Optional: if true, report the encoding, BOM, line ending, upgrades and ' +
    'warnings that a write would produce, without writing.'));
  AProps.AddPair('force', MakeProp('boolean',
    'Optional (default false): allow replacing an existing binary Delphi form ' +
    '(format "binary-dfm") with text content. Without force such a write is rejected.'));
end;

function TWriteFileTool.BuildInputSchema: TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('type', 'object');
    LProps := TJSONObject.Create;
    LProps.AddPair('path', MakeProp('string', 'Absolute path to the file to write.'));
    LProps.AddPair('content', MakeProp('string', 'UTF-8 content to write.'));
    AddWriteOptionProps(LProps);
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

function ParseWriteOptions(AArgs: TJSONObject): TWriteOptions;
var
  LEncodingName, LLineEndingName: string;
begin
  Result := MakeDefaultWriteOptions;
  LEncodingName := GetStringArg(AArgs, 'encoding', '');
  if LEncodingName <> '' then
  begin
    Result.EncodingOverride := EncodingIdFromName(LEncodingName);
    if Result.EncodingOverride = TEncodingId.Unknown then
      raise Exception.CreateFmt('Unsupported encoding: %s', [LEncodingName]);
  end;
  LLineEndingName := GetStringArg(AArgs, 'lineEnding', '');
  if LLineEndingName <> '' then
  begin
    Result.LineEndingOverride := LineEndingFromName(LLineEndingName);
    if not (Result.LineEndingOverride in [TLineEnding.CrLf, TLineEnding.Lf, TLineEnding.Cr]) then
      raise Exception.CreateFmt('Unsupported lineEnding: %s (use CRLF, LF or CR)',
        [LLineEndingName]);
  end;
  if HasArg(AArgs, 'hasBom') then
  begin
    if GetBoolArg(AArgs, 'hasBom', False) then
      Result.HasBomOverride := 1
    else
      Result.HasBomOverride := 0;
  end;
  Result.CreateIfMissing := GetBoolArg(AArgs, 'createIfMissing', True);
  Result.DryRun := GetBoolArg(AArgs, 'dryRun', False);
  Result.Force := GetBoolArg(AArgs, 'force', False);
end;

procedure AddWriteResultFields(AJson: TJSONObject; const AResult: TWriteResult;
  ADryRun: Boolean);
begin
  AJson.AddPair('encoding', EncodingIdName(AResult.EncodingId));
  AJson.AddPair('hasBom', TJSONBool.Create(AResult.HasBom));
  AJson.AddPair('lineEnding', LineEndingName(AResult.LineEnding));
  AJson.AddPair('bytesWritten', TJSONNumber.Create(AResult.BytesWritten));
  AJson.AddPair('created', TJSONBool.Create(AResult.Created));
  AJson.AddPair('source', EncodingSourceName(AResult.Source));
  if AResult.PreviousEncodingId <> TEncodingId.Unknown then
    AJson.AddPair('previousEncoding', EncodingIdName(AResult.PreviousEncodingId));
  AddUpgradeAndWarningFields(AJson, AResult.UpgradedFrom, AResult.Warnings, ADryRun);
end;

procedure AddUpgradeAndWarningFields(AJson: TJSONObject;
  AUpgradedFrom: TEncodingId; const AWarnings: TArray<string>; ADryRun: Boolean);
var
  LWarnings: TJSONArray;
  LWarning: string;
begin
  if AUpgradedFrom <> TEncodingId.Unknown then
    AJson.AddPair('upgradedFrom', EncodingIdName(AUpgradedFrom));
  if Length(AWarnings) > 0 then
  begin
    LWarnings := TJSONArray.Create;
    AJson.AddPair('warnings', LWarnings);
    for LWarning in AWarnings do
      LWarnings.Add(LWarning);
  end;
  if ADryRun then
    AJson.AddPair('dryRun', TJSONBool.Create(True));
end;

function BuildUnsupportedCharsJson(const APath: string;
  AError: EUnsupportedCharsError): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('path', APath);
    Result.AddPair('error', AError.Message);
    Result.AddPair('encoding', EncodingIdName(AError.EncodingId));
    Result.AddPair('unrepresentableChars', TJSONNumber.Create(AError.CharCount));
    Result.AddPair('sample', AError.FirstSample);
  except
    Result.Free;
    raise;
  end;
end;

function BuildConcurrencyErrorJson(const APath, AReason, AMessage: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('path', APath);
    Result.AddPair('error', AMessage);
    Result.AddPair('reason', AReason);
    Result.AddPair('retryable', TJSONBool.Create(True));
  except
    Result.Free;
    raise;
  end;
end;

function TWriteFileTool.Execute(AArguments: TJSONObject): TJSONObject;
var
  LPath, LContent: string;
  LOptions: TWriteOptions;
  LWriteResult: TWriteResult;
  LJson: TJSONObject;
begin
  LPath := GetStringArg(AArguments, 'path', '');
  if LPath = '' then
    raise Exception.Create('Missing required argument "path"');
  ValidatePathInWorkspace(LPath);
  LContent := GetStringArg(AArguments, 'content', '');
  LOptions := ParseWriteOptions(AArguments);

  try
    LWriteResult := WriteTextFile(LPath, LContent, FCacheManager, LOptions);
  except
    on E: EUnsupportedCharsError do
      Exit(BuildJsonTextResult(BuildUnsupportedCharsJson(LPath, E), True));
    on E: EBinaryDfmError do
      Exit(BuildJsonTextResult(BuildFormatErrorJson(LPath, FORMAT_BINARY_DFM, E.Message), True));
    on E: EFileLockedError do
      Exit(BuildJsonTextResult(BuildConcurrencyErrorJson(LPath, 'locked', E.Message), True));
    on E: EFileModifiedError do
      Exit(BuildJsonTextResult(BuildConcurrencyErrorJson(LPath, 'modified', E.Message), True));
  end;
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('path', LPath);
    AddWriteResultFields(LJson, LWriteResult, LOptions.DryRun);
  except
    LJson.Free;
    raise;
  end;
  Result := BuildJsonTextResult(LJson, False);
end;

end.
