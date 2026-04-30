unit FileIO.Writer;

/// <summary>
///   Encoding-aware filskrivning. Bevarer eller tilsidesætter encoding ved
///   skrivning, og kan rapportere tegn der ikke kan repræsenteres.
/// </summary>

interface

uses
  System.SysUtils,
  System.Classes,
  Encoding.Types,
  Encoding.Cache,
  Encoding.CacheManager;

type
  TWriteOptions = record
    EncodingOverride: TEncodingId;       // Unknown = bevar eksisterende
    LineEndingOverride: TLineEnding;     // Unknown = bevar eksisterende eller default CRLF
    HasBomOverride: Integer;             // -1 = ikke sat, 0 = uden BOM, 1 = med BOM
    CreateIfMissing: Boolean;            // True = opret hvis filen ikke findes
  end;

  TWriteResult = record
    EncodingId: TEncodingId;
    HasBom: Boolean;
    LineEnding: TLineEnding;
    BytesWritten: Int64;
    UnsupportedCharCount: Integer; // Antal tegn der ikke kunne repræsenteres
    Created: Boolean;
  end;

  EUnsupportedCharsError = class(Exception)
  strict private
    FCharCount: Integer;
    FFirstSample: string;
  public
    constructor Create(ACharCount: Integer; const AFirstSample: string);
    property CharCount: Integer read FCharCount;
    property FirstSample: string read FFirstSample;
  end;

function MakeDefaultWriteOptions: TWriteOptions;

/// <summary>
///   Skriver UTF-8 indhold til en fil med korrekt encoding-konvertering.
///   Hvis filen findes og der ikke er givet override, bruges cachet encoding.
///   Hvis filen ikke findes og CreateIfMissing er True, defaultes til UTF-8 m. BOM.
/// </summary>
function WriteTextFile(const APath: string; const AContent: string;
  ACacheManager: TCacheManager; const AOptions: TWriteOptions): TWriteResult;

implementation

uses
  System.IOUtils,
  System.Math,
  Encoding.Detector,
  MCP.Logging;

{ EUnsupportedCharsError }

constructor EUnsupportedCharsError.Create(ACharCount: Integer; const AFirstSample: string);
begin
  inherited CreateFmt(
    'Cannot encode %d character(s) in target encoding. First problematic chars: "%s"',
    [ACharCount, AFirstSample]);
  FCharCount := ACharCount;
  FFirstSample := AFirstSample;
end;

function MakeDefaultWriteOptions: TWriteOptions;
begin
  Result.EncodingOverride := TEncodingId.Unknown;
  Result.LineEndingOverride := TLineEnding.Unknown;
  Result.HasBomOverride := -1;
  Result.CreateIfMissing := True;
end;

function NormalizeLineEndings(const AContent: string; ALineEnding: TLineEnding): string;
var
  LBuilder: TStringBuilder;
  I: Integer;
  LCh: Char;
  LSep: string;
begin
  if (ALineEnding = TLineEnding.Unknown) or (ALineEnding = TLineEnding.Mixed) then
    Exit(AContent);
  case ALineEnding of
    TLineEnding.CrLf: LSep := #13#10;
    TLineEnding.Lf: LSep := #10;
    TLineEnding.Cr: LSep := #13;
  else
    Exit(AContent);
  end;
  LBuilder := TStringBuilder.Create(Length(AContent) + 32);
  try
    I := 1;
    while I <= Length(AContent) do
    begin
      LCh := AContent[I];
      if LCh = #13 then
      begin
        LBuilder.Append(LSep);
        if (I < Length(AContent)) and (AContent[I + 1] = #10) then
          Inc(I, 2)
        else
          Inc(I);
        Continue;
      end
      else if LCh = #10 then
      begin
        LBuilder.Append(LSep);
        Inc(I);
        Continue;
      end
      else
        LBuilder.Append(LCh);
      Inc(I);
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function CountUnsupportedChars(const AContent: string; AEncoding: TEncoding;
  out AFirstSample: string): Integer;
var
  LRoundtrip: TBytes;
  LBack: string;
  I, LMaxSample: Integer;
  LBuilder: TStringBuilder;
begin
  // Encode → decode → sammenlign per tegn
  LRoundtrip := AEncoding.GetBytes(AContent);
  LBack := AEncoding.GetString(LRoundtrip);
  if LBack = AContent then
  begin
    AFirstSample := '';
    Exit(0);
  end;
  Result := 0;
  LBuilder := TStringBuilder.Create;
  try
    LMaxSample := 10;
    // Bemærk: roundtrip kan give forskellig længde hvis tegn erstattes med '?'
    if Length(LBack) = Length(AContent) then
    begin
      for I := 1 to Length(AContent) do
      begin
        if LBack[I] <> AContent[I] then
        begin
          Inc(Result);
          if LBuilder.Length < LMaxSample then
            LBuilder.Append(AContent[I]);
        end;
      end;
    end
    else
    begin
      // Fallback: tæl heuristisk
      Result := Abs(Length(AContent) - Length(LBack)) + 1;
      LBuilder.Append('(unknown)');
    end;
    AFirstSample := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

procedure WriteBytesToFile(const APath: string; const ABytes: TBytes);
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then
      LStream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    LStream.Free;
  end;
end;

procedure ResolveTargetEncoding(const APath: string; ACacheManager: TCacheManager;
  const AOptions: TWriteOptions; out AEntry: TCacheEntry; out ARelative: string;
  out ACache: TEncodingCache);
var
  LDetected: TDetectedEncoding;
  LOverrideId: TEncodingId;
  LExisting: Boolean;
  LResolved: Boolean;
begin
  ACacheManager.Resolve(APath, ACache, ARelative);
  LExisting := TFile.Exists(APath);
  LResolved := False;
  AEntry := Default(TCacheEntry);

  // Find startpunkt med faldende prioritet
  if AOptions.EncodingOverride <> TEncodingId.Unknown then
  begin
    AEntry.EncodingId := AOptions.EncodingOverride;
    AEntry.HasBom := False;
    AEntry.LineEnding := TLineEnding.CrLf;
    AEntry.DetectedAt := Now;
    LResolved := True;
  end;
  if (not LResolved) and ACache.TryGet(ARelative, AEntry) then
    LResolved := True;
  if (not LResolved) and LExisting then
  begin
    LDetected := DetectFileEncoding(APath);
    AEntry.EncodingId := LDetected.Id;
    AEntry.HasBom := LDetected.HasBom;
    AEntry.LineEnding := LDetected.LineEnding;
    AEntry.DetectedAt := Now;
    LResolved := True;
  end;
  if (not LResolved) and ACache.TryGetExtensionOverride(ARelative, LOverrideId) then
  begin
    AEntry.EncodingId := LOverrideId;
    AEntry.HasBom := False;
    AEntry.LineEnding := TLineEnding.CrLf;
    AEntry.DetectedAt := Now;
    LResolved := True;
  end;
  if not LResolved then
  begin
    // Ny fil uden hints → UTF-8 med BOM som default
    AEntry.EncodingId := TEncodingId.Utf8;
    AEntry.HasBom := True;
    AEntry.LineEnding := TLineEnding.CrLf;
    AEntry.DetectedAt := Now;
  end;

  // Anvend overrides oven på resolved-værdien
  if AOptions.LineEndingOverride <> TLineEnding.Unknown then
    AEntry.LineEnding := AOptions.LineEndingOverride;
  if AOptions.HasBomOverride = 0 then
    AEntry.HasBom := False
  else if AOptions.HasBomOverride = 1 then
    AEntry.HasBom := True;
end;

function WriteTextFile(const APath: string; const AContent: string;
  ACacheManager: TCacheManager; const AOptions: TWriteOptions): TWriteResult;
var
  LCache: TEncodingCache;
  LRelative: string;
  LEntry: TCacheEntry;
  LEncoding: TEncoding;
  LContent, LSample: string;
  LBytes, LBom, LFinal: TBytes;
  LExisting: Boolean;
  LUnsupportedCount: Integer;
begin
  Result := Default(TWriteResult);
  LExisting := TFile.Exists(APath);
  if (not LExisting) and (not AOptions.CreateIfMissing) then
    raise Exception.CreateFmt('File does not exist and CreateIfMissing is false: %s', [APath]);

  // Sørg for at directory eksisterer
  if not LExisting then
    TDirectory.CreateDirectory(TPath.GetDirectoryName(APath));

  ResolveTargetEncoding(APath, ACacheManager, AOptions, LEntry, LRelative, LCache);
  Result.Created := not LExisting;

  // Normaliser line-endings i indholdet
  LContent := NormalizeLineEndings(AContent, LEntry.LineEnding);

  // Konverter til target encoding
  case LEntry.EncodingId of
    TEncodingId.Ascii,
    TEncodingId.Utf8:
      LEncoding := TEncoding.UTF8;
    TEncodingId.Utf16Le:
      LEncoding := TEncoding.Unicode;
    TEncodingId.Utf16Be:
      LEncoding := TEncoding.BigEndianUnicode;
  else
    LEncoding := TEncoding.GetEncoding(EncodingIdCodePage(LEntry.EncodingId));
  end;
  try
    // Tjek for tab af tegn (kun ved ikke-Unicode targets)
    LUnsupportedCount := 0;
    LSample := '';
    if not (LEntry.EncodingId in [TEncodingId.Utf8, TEncodingId.Ascii,
                                  TEncodingId.Utf16Le, TEncodingId.Utf16Be,
                                  TEncodingId.Utf32Le, TEncodingId.Utf32Be]) then
    begin
      LUnsupportedCount := CountUnsupportedChars(LContent, LEncoding, LSample);
      if LUnsupportedCount > 0 then
        raise EUnsupportedCharsError.Create(LUnsupportedCount, LSample);
    end;
    LBytes := LEncoding.GetBytes(LContent);
    if LEntry.HasBom then
      LBom := LEncoding.GetPreamble
    else
      SetLength(LBom, 0);
    SetLength(LFinal, Length(LBom) + Length(LBytes));
    if Length(LBom) > 0 then
      Move(LBom[0], LFinal[0], Length(LBom));
    if Length(LBytes) > 0 then
      Move(LBytes[0], LFinal[Length(LBom)], Length(LBytes));
  finally
    if not TEncoding.IsStandardEncoding(LEncoding) then
      LEncoding.Free;
  end;

  WriteBytesToFile(APath, LFinal);
  Result.EncodingId := LEntry.EncodingId;
  Result.HasBom := LEntry.HasBom;
  Result.LineEnding := LEntry.LineEnding;
  Result.BytesWritten := Length(LFinal);
  Result.UnsupportedCharCount := LUnsupportedCount;

  // Opdatér cache (bevar manual flag hvis det allerede var sat)
  LEntry.DetectedAt := Now;
  LCache.Put(LRelative, LEntry);
end;

end.
