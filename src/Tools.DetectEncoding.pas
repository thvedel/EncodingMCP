unit Tools.DetectEncoding;

/// <summary>
///   MCP tool: detect_encoding. Returns the detected encoding for a file
///   without reading the full content into the result.
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  MCP.Tools,
  Encoding.CacheManager;

type
  TDetectEncodingTool = class(TInterfacedObject, IMcpTool)
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
  Encoding.Cache,
  Encoding.Detector,
  Encoding.Workspace,
  Encoding.Heuristics,
  FileIO.Reader,
  Tools.ReadFile;

constructor TDetectEncodingTool.Create(ACacheManager: TCacheManager);
begin
  inherited Create;
  FCacheManager := ACacheManager;
end;

function TDetectEncodingTool.GetName: string;
begin
  Result := 'detect_encoding';
end;

function TDetectEncodingTool.GetDescription: string;
begin
  Result :=
    'Detect the text encoding of a file (BOM, UTF-8, UTF-16, Windows-1252, ' +
    'ISO-8859-1/15) and return confidence and candidate scores. Uses exactly the ' +
    'same resolution as read_text_file (BOM, per-file override, pattern override, ' +
    'detection of the complete file), so both tools always agree; "source" tells ' +
    'which rule decided. For ASCII results "writeRecommendation" and "note" ' +
    'explain that the encoding cannot be told from the bytes. Binary Delphi forms ' +
    'are reported with "format": "binary-dfm". Does not read the content into ' +
    'the result.';
end;

function TDetectEncodingTool.BuildInputSchema: TJSONObject;
var
  LProps, LPath: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('type', 'object');
    LProps := TJSONObject.Create;
    LPath := TJSONObject.Create;
    LPath.AddPair('type', 'string');
    LPath.AddPair('description', 'Absolute path to the file.');
    LProps.AddPair('path', LPath);
    Result.AddPair('properties', LProps);
    LRequired := TJSONArray.Create;
    LRequired.Add('path');
    Result.AddPair('required', LRequired);
  except
    Result.Free;
    raise;
  end;
end;

function TDetectEncodingTool.Execute(AArguments: TJSONObject): TJSONObject;
var
  LPath, LRelative: string;
  LBytes: TBytes;
  LCache: TEncodingCache;
  LSource: TEncodingSource;
  LDetected: TDetectedEncoding;
  LScores: TCodepageScores;
  LJson: TJSONObject;
  LCandidates: TJSONArray;
  LCandidate: TJSONObject;
  I: Integer;
begin
  LPath := GetStringArg(AArguments, 'path');
  if LPath = '' then
    raise EInvalidArgumentError.Create('Missing required argument "path"');
  ValidatePathInWorkspace(LPath);
  if not FileExists(LPath) then
    raise Exception.CreateFmt('File not found: %s', [LPath]);
  // The complete file is analysed (no sampling), so a late non-ASCII byte
  // cannot make detect_encoding disagree with read_text_file.
  LBytes := ReadFileBytes(LPath);
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('path', LPath);
    LJson.AddPair('bytesRead', TJSONNumber.Create(Length(LBytes)));
    if IsBinaryDfm(LBytes) then
    begin
      LJson.AddPair('format', FORMAT_BINARY_DFM);
      LJson.AddPair('note',
        'Binary Delphi form: it has no text encoding and cannot be read, edited ' +
        'or overwritten as text (write tools require force).');
    end
    else
    begin
      FCacheManager.Resolve(LPath, LCache, LRelative);
      LDetected := ResolveFileEncoding(LBytes, LCache, LRelative, LSource);
      LJson.AddPair('format', FORMAT_TEXT);
      LJson.AddPair('encoding', EncodingIdName(LDetected.Id));
      LJson.AddPair('hasBom', TJSONBool.Create(LDetected.HasBom));
      LJson.AddPair('confidence', TJSONNumber.Create(LDetected.Confidence));
      LJson.AddPair('lineEnding', LineEndingName(LDetected.LineEnding));
      LJson.AddPair('source', EncodingSourceName(LSource));
      AddAsciiAdvice(LJson, LDetected.Id);
      LCandidates := TJSONArray.Create;
      LJson.AddPair('candidates', LCandidates);
      LScores := ScoreCodepages(LBytes);
      for I := 0 to High(LScores) do
      begin
        LCandidate := TJSONObject.Create;
        LCandidate.AddPair('encoding', EncodingIdName(LScores[I].EncodingId));
        LCandidate.AddPair('score', TJSONNumber.Create(LScores[I].Score));
        LCandidates.AddElement(LCandidate);
      end;
    end;
  except
    LJson.Free;
    raise;
  end;
  Result := BuildJsonTextResult(LJson, False);
end;

end.
