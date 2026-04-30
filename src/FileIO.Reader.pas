unit FileIO.Reader;

/// <summary>
///   Encoding-aware filsslæsning. Detekterer encoding (eller bruger cache),
///   konverterer til UTF-8 string, og returnerer metadata.
/// </summary>

interface

uses
  System.SysUtils,
  System.Classes,
  Encoding.Types,
  Encoding.Cache,
  Encoding.CacheManager;

type
  TReadResult = record
    Content: string;          // UTF-8 (Delphi UnicodeString)
    EncodingId: TEncodingId;
    HasBom: Boolean;
    LineEnding: TLineEnding;
    Confidence: Double;
    FromCache: Boolean;
    BytesRead: Int64;
    TotalLines: Integer;
    ReturnedLines: Integer;
  end;

/// <summary>
///   Læser en fil, detekterer (eller henter cachet) encoding, og returnerer
///   indholdet som UTF-8 streng. Cachen opdateres med detekteret encoding.
/// </summary>
/// <param name="APath">Absolut sti til filen.</param>
/// <param name="ACacheManager">Cache-manager. Må ikke være nil.</param>
/// <param name="AHead">Hvis &gt; 0, returnér kun de første N linjer.</param>
/// <param name="ATail">Hvis &gt; 0, returnér kun de sidste N linjer.</param>
function ReadTextFile(const APath: string; ACacheManager: TCacheManager;
  AHead: Integer = 0; ATail: Integer = 0): TReadResult;

implementation

uses
  System.IOUtils,
  System.Math,
  System.DateUtils,
  Encoding.Detector,
  MCP.Logging;

function ReadAllBytes(const APath: string): TBytes;
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, LStream.Size);
    if LStream.Size > 0 then
      LStream.ReadBuffer(Result[0], LStream.Size);
  finally
    LStream.Free;
  end;
end;

function StripBom(const ABytes: TBytes; ABomLength: Integer): TBytes;
begin
  if (ABomLength <= 0) or (Length(ABytes) <= ABomLength) then
  begin
    if ABomLength >= Length(ABytes) then
      Exit(nil);
    Exit(ABytes);
  end;
  SetLength(Result, Length(ABytes) - ABomLength);
  Move(ABytes[ABomLength], Result[0], Length(Result));
end;

function DecodeBytes(const ABytes: TBytes; AId: TEncodingId; AHasBom: Boolean): string;
var
  LEncoding: TEncoding;
  LBom: TBytes;
  LBomLen: Integer;
  LStripped: TBytes;
begin
  if Length(ABytes) = 0 then
    Exit('');
  case AId of
    TEncodingId.Ascii,
    TEncodingId.Utf8:
      LEncoding := TEncoding.UTF8;
    TEncodingId.Utf16Le:
      LEncoding := TEncoding.Unicode;
    TEncodingId.Utf16Be:
      LEncoding := TEncoding.BigEndianUnicode;
  else
    LEncoding := TEncoding.GetEncoding(EncodingIdCodePage(AId));
  end;
  try
    LBomLen := 0;
    if AHasBom then
    begin
      LBom := LEncoding.GetPreamble;
      LBomLen := Length(LBom);
    end;
    LStripped := StripBom(ABytes, LBomLen);
    Result := LEncoding.GetString(LStripped);
  finally
    if not TEncoding.IsStandardEncoding(LEncoding) then
      LEncoding.Free;
  end;
end;

function ApplyHeadTail(const AContent: string; AHead, ATail: Integer;
  out ATotalLines, AReturnedLines: Integer): string;
var
  LLines: TArray<string>;
  LStart, LEnd, I: Integer;
  LBuilder: TStringBuilder;
begin
  // Bevar oprindelige line-endings ved at splitte manuelt
  if AContent = '' then
  begin
    ATotalLines := 0;
    AReturnedLines := 0;
    Exit('');
  end;
  // Tæl linjer ved at splitte på LF (CR håndteres som del af linjeindholdet)
  LLines := AContent.Split([#10]);
  ATotalLines := Length(LLines);
  if (AHead <= 0) and (ATail <= 0) then
  begin
    AReturnedLines := ATotalLines;
    Exit(AContent);
  end;
  if (AHead > 0) and (AHead < ATotalLines) then
  begin
    LStart := 0;
    LEnd := AHead - 1;
  end
  else if (ATail > 0) and (ATail < ATotalLines) then
  begin
    LStart := ATotalLines - ATail;
    LEnd := ATotalLines - 1;
  end
  else
  begin
    AReturnedLines := ATotalLines;
    Exit(AContent);
  end;
  LBuilder := TStringBuilder.Create;
  try
    for I := LStart to LEnd do
    begin
      LBuilder.Append(LLines[I]);
      if I < LEnd then
        LBuilder.Append(#10);
    end;
    AReturnedLines := LEnd - LStart + 1;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function ReadTextFile(const APath: string; ACacheManager: TCacheManager;
  AHead: Integer; ATail: Integer): TReadResult;
var
  LBytes: TBytes;
  LDetected: TDetectedEncoding;
  LCache: TEncodingCache;
  LRelative: string;
  LEntry: TCacheEntry;
  LHasCached: Boolean;
  LOverrideId: TEncodingId;
  LBom: TBomInfo;
begin
  if not TFile.Exists(APath) then
    raise Exception.CreateFmt('File not found: %s', [APath]);
  LBytes := ReadAllBytes(APath);
  Result := Default(TReadResult);
  Result.BytesRead := Length(LBytes);
  Result.FromCache := False;

  ACacheManager.Resolve(APath, LCache, LRelative);
  LHasCached := LCache.TryGet(LRelative, LEntry);

  // Bestem encoding-prioritet:
  //   1) BOM (altid 100% sikker)
  //   2) Cachet manuel override (sat af bruger)
  //   3) Extension-override fra cache (fx *.pas → Windows-1252)
  //   4) Cachet auto-detekteret entry hvis filen er uændret (vi gendetekterer for sikkerhed)
  //   5) Frisk detektion
  LBom := DetectBom(LBytes);
  if LBom.Detected then
  begin
    LDetected.Id := LBom.EncodingId;
    LDetected.HasBom := True;
    LDetected.Confidence := 1.0;
    LDetected.LineEnding := DetectLineEnding(LBytes);
  end
  else if LHasCached and LEntry.Manual then
  begin
    LDetected.Id := LEntry.EncodingId;
    LDetected.HasBom := LEntry.HasBom;
    LDetected.Confidence := 1.0;
    LDetected.LineEnding := DetectLineEnding(LBytes);
    Result.FromCache := True;
  end
  else if LCache.TryGetExtensionOverride(LRelative, LOverrideId) then
  begin
    LDetected.Id := LOverrideId;
    LDetected.HasBom := False;
    LDetected.Confidence := 0.95;
    LDetected.LineEnding := DetectLineEnding(LBytes);
    Result.FromCache := True;
  end
  else
  begin
    LDetected := DetectEncoding(LBytes);
  end;

  Result.Content := DecodeBytes(LBytes, LDetected.Id, LDetected.HasBom);
  Result.EncodingId := LDetected.Id;
  Result.HasBom := LDetected.HasBom;
  Result.LineEnding := LDetected.LineEnding;
  Result.Confidence := LDetected.Confidence;
  Result.Content := ApplyHeadTail(Result.Content, AHead, ATail,
    Result.TotalLines, Result.ReturnedLines);

  // Opdatér cache (medmindre der er en manuel entry vi ikke bør overskrive)
  if not (LHasCached and LEntry.Manual) then
  begin
    LEntry := Default(TCacheEntry);
    LEntry.EncodingId := LDetected.Id;
    LEntry.HasBom := LDetected.HasBom;
    LEntry.LineEnding := LDetected.LineEnding;
    LEntry.Manual := False;
    LEntry.DetectedAt := Now;
    LCache.Put(LRelative, LEntry);
  end;
end;

end.
