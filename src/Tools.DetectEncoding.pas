unit Tools.DetectEncoding;

/// <summary>
///   MCP-tool: detect_encoding. Returnerer detekteret encoding for en fil
///   uden at læse hele indholdet ind i resultatet.
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
  System.Classes,
  System.IOUtils,
  Encoding.Types,
  Encoding.Detector,
  Encoding.Heuristics;

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
    'ISO-8859-1/15) and return confidence and candidate scores. Useful for ' +
    'diagnosing encoding issues without reading file content.';
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

function TDetectEncodingTool.Execute(AArguments: TJSONObject): TJSONObject;
var
  LPath: string;
  LStream: TFileStream;
  LBytes: TBytes;
  LToRead: Int64;
  LDetected: TDetectedEncoding;
  LScores: TCodepageScores;
  LJson: TJSONObject;
  LCandidates: TJSONArray;
  LCandidate: TJSONObject;
  I: Integer;
begin
  LPath := GetStringArg(AArguments, 'path');
  if LPath = '' then
    raise Exception.Create('Missing required argument "path"');
  if not TFile.Exists(LPath) then
    raise Exception.CreateFmt('File not found: %s', [LPath]);
  LStream := TFileStream.Create(LPath, fmOpenRead or fmShareDenyWrite);
  try
    LToRead := LStream.Size;
    if LToRead > 65536 then
      LToRead := 65536;
    SetLength(LBytes, LToRead);
    if LToRead > 0 then
      LStream.ReadBuffer(LBytes[0], LToRead);
  finally
    LStream.Free;
  end;
  LDetected := DetectEncoding(LBytes);
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('path', LPath);
    LJson.AddPair('encoding', EncodingIdName(LDetected.Id));
    LJson.AddPair('hasBom', TJSONBool.Create(LDetected.HasBom));
    LJson.AddPair('confidence', TJSONNumber.Create(LDetected.Confidence));
    LJson.AddPair('lineEnding', LineEndingName(LDetected.LineEnding));
    LCandidates := TJSONArray.Create;
    LScores := ScoreCodepages(LBytes);
    for I := 0 to High(LScores) do
    begin
      LCandidate := TJSONObject.Create;
      LCandidate.AddPair('encoding', EncodingIdName(LScores[I].EncodingId));
      LCandidate.AddPair('score', TJSONNumber.Create(LScores[I].Score));
      LCandidates.AddElement(LCandidate);
    end;
    LJson.AddPair('candidates', LCandidates);
  except
    LJson.Free;
    raise;
  end;
  Result := BuildJsonTextResult(LJson, False);
end;

end.
