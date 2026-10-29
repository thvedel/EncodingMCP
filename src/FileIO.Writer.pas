unit FileIO.Writer;

/// <summary>
///   Encoding-aware file writing. Preserves or overrides encoding on write,
///   and can report characters that cannot be represented.
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
    EncodingOverride: TEncodingId;       // Unknown = preserve existing
    LineEndingOverride: TLineEnding;     // Unknown = preserve existing or default CRLF
    HasBomOverride: Integer;             // -1 = not set, 0 = without BOM, 1 = with BOM
    CreateIfMissing: Boolean;            // True = create if file does not exist
    DryRun: Boolean;                     // True = compute the result without writing
    Force: Boolean;                      // True = allow replacing a binary DFM with text
  end;

  TWriteResult = record
    EncodingId: TEncodingId;
    HasBom: Boolean;
    LineEnding: TLineEnding;
    BytesWritten: Int64;           // Bytes written (or that would be written on dry run)
    UnsupportedCharCount: Integer; // Number of characters that could not be represented
    Created: Boolean;
    Source: TEncodingSource;       // Where the target encoding came from
    PreviousEncodingId: TEncodingId; // Encoding of the existing file (Unknown for new files)
    UpgradedFrom: TEncodingId;     // Set when the encoding had to be upgraded (e.g. from ASCII)
    Warnings: TArray<string>;
  end;

  EUnsupportedCharsError = class(Exception)
  strict private
    FCharCount: Integer;
    FFirstSample: string;
    FEncodingId: TEncodingId;
  public
    constructor Create(ACharCount: Integer; const AFirstSample: string;
      AEncodingId: TEncodingId);
    property CharCount: Integer read FCharCount;
    property FirstSample: string read FFirstSample;
    property EncodingId: TEncodingId read FEncodingId;
  end;

function MakeDefaultWriteOptions: TWriteOptions;

/// <summary>
///   Writes UTF-8 content to a file with correct encoding conversion.
///   The target encoding is resolved as follows:
///   1) An explicit EncodingOverride always wins.
///   2) An existing file is re-read from disk and resolved with the same
///      priority as reading (BOM, per-file override, pattern override,
///      detection) - so external changes and pattern overrides are honoured.
///   3) A new file uses a per-file override, a pattern override, or
///      UTF-8 with BOM.
///   A file detected as ASCII that receives non-ASCII content is upgraded to
///   Windows-1252 (never to BOM-less UTF-8); ASCII requested with a BOM is
///   written as UTF-8 with BOM. Content that cannot be represented in the
///   target encoding raises EUnsupportedCharsError. An existing binary Delphi
///   form raises EBinaryDfmError unless AOptions.Force is set; with Force it
///   is replaced as if the file were new.
/// </summary>
function WriteTextFile(const APath: string; const AContent: string;
  ACacheManager: TCacheManager; const AOptions: TWriteOptions): TWriteResult;

/// <summary>True if the string contains characters outside 7-bit ASCII.</summary>
function ContainsNonAscii(const AText: string): Boolean;

/// <summary>
///   Converts every line break (CRLF, LF or CR) in AContent to ALineEnding.
///   Unknown and Mixed leave the content unchanged.
/// </summary>
function NormalizeLineEndings(const AContent: string; ALineEnding: TLineEnding): string;

/// <summary>
///   The line-ending style used when a file carries none of its own (a single
///   unterminated line or an empty file): the style remembered for the file
///   in the cache, otherwise CRLF. Writer and editor share this so the
///   editor's diff shows exactly what reaches the disk.
/// </summary>
function FallbackLineEnding(ACache: TEncodingCache; const ARelativePath: string): TLineEnding;

implementation

uses
  System.IOUtils,
  System.Math,
  System.Character,
  Winapi.Windows,
  Encoding.Detector,
  FileIO.Reader,
  MCP.Logging;

{ EUnsupportedCharsError }

constructor EUnsupportedCharsError.Create(ACharCount: Integer;
  const AFirstSample: string; AEncodingId: TEncodingId);
begin
  inherited CreateFmt(
    'Cannot encode %d character(s) in %s (unrepresentableChars=%d). ' +
    'First problematic chars: "%s". Nothing was written. Choose an encoding ' +
    'that can represent the content (e.g. encoding "UTF-8" with hasBom true).',
    [ACharCount, EncodingIdName(AEncodingId), ACharCount, AFirstSample]);
  FCharCount := ACharCount;
  FFirstSample := AFirstSample;
  FEncodingId := AEncodingId;
end;

function MakeDefaultWriteOptions: TWriteOptions;
begin
  Result.EncodingOverride := TEncodingId.Unknown;
  Result.LineEndingOverride := TLineEnding.Unknown;
  Result.HasBomOverride := -1;
  Result.CreateIfMissing := True;
  Result.DryRun := False;
  Result.Force := False;
end;

function ContainsNonAscii(const AText: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(AText) do
    if Ord(AText[I]) > $7F then
      Exit(True);
  Result := False;
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

function FallbackLineEnding(ACache: TEncodingCache; const ARelativePath: string): TLineEnding;
var
  LEntry: TCacheEntry;
begin
  if ACache.TryGet(ARelativePath, LEntry) and
     (LEntry.LineEnding in [TLineEnding.Lf, TLineEnding.CrLf, TLineEnding.Cr]) then
    Result := LEntry.LineEnding
  else
    Result := TLineEnding.CrLf;
end;

function CountUnsupportedChars(const AContent: string; AEncoding: TEncoding;
  out AFirstSample: string): Integer;
const
  MAX_SAMPLE_CHARS = 10;
var
  I, LLen, LSampleCount: Integer;
  LCodePoint: string;
  LBuilder: TStringBuilder;
begin
  // Fast path: the whole text survives an encode/decode roundtrip
  if AEncoding.GetString(AEncoding.GetBytes(AContent)) = AContent then
  begin
    AFirstSample := '';
    Exit(0);
  end;
  // Slow path: roundtrip each code point, so a surrogate pair (emoji) counts
  // as one character and the sample stays readable. Comparing the roundtrip
  // (rather than only the default-char flag) also catches best-fit mappings
  // such as U+0100 -> 'A'.
  Result := 0;
  LSampleCount := 0;
  LBuilder := TStringBuilder.Create;
  try
    I := 1;
    while I <= Length(AContent) do
    begin
      if (I < Length(AContent)) and AContent[I].IsHighSurrogate and
         AContent[I + 1].IsLowSurrogate then
        LLen := 2
      else
        LLen := 1;
      LCodePoint := Copy(AContent, I, LLen);
      if AEncoding.GetString(AEncoding.GetBytes(LCodePoint)) <> LCodePoint then
      begin
        Inc(Result);
        if LSampleCount < MAX_SAMPLE_CHARS then
        begin
          LBuilder.Append(LCodePoint);
          Inc(LSampleCount);
        end;
      end;
      Inc(I, LLen);
    end;
    AFirstSample := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

procedure WriteBytesToFile(const APath: string; const ABytes: TBytes);
var
  LTempPath: string;
  LStream: TFileStream;
  LMoved: Boolean;
begin
  LTempPath := APath + '.tmp';
  LStream := TFileStream.Create(LTempPath, fmCreate);
  try
    if Length(ABytes) > 0 then
      LStream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    LStream.Free;
  end;
  // Atomic rename: temp file -> final file. If both the rename and the
  // fallback fail, the temp file is removed so no stray .tmp is left behind.
  LMoved := False;
  try
    if MoveFileEx(PChar(LTempPath), PChar(APath),
         MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      LMoved := True
    else
    begin
      TLog.Warning('MoveFileEx failed, trying fallback: %s',
        [SysErrorMessage(GetLastError)]);
      if TFile.Exists(APath) then
        TFile.Delete(APath);
      TFile.Move(LTempPath, APath);
      LMoved := True;
    end;
  finally
    if (not LMoved) and TFile.Exists(LTempPath) then
      TFile.Delete(LTempPath);
  end;
end;

type
  TTargetEncoding = record
    Id: TEncodingId;
    HasBom: Boolean;
    LineEnding: TLineEnding;
    Source: TEncodingSource;
  end;

procedure AddWarning(var AResult: TWriteResult; const AWarning: string);
begin
  SetLength(AResult.Warnings, Length(AResult.Warnings) + 1);
  AResult.Warnings[High(AResult.Warnings)] := AWarning;
end;

function CreateTextEncoding(AId: TEncodingId): TEncoding;
begin
  case AId of
    TEncodingId.Utf8:
      Result := TEncoding.UTF8;
    TEncodingId.Utf16Le:
      Result := TEncoding.Unicode;
    TEncodingId.Utf16Be:
      Result := TEncoding.BigEndianUnicode;
  else
    // Includes ASCII (code page 20127), so non-ASCII content is detected as
    // unrepresentable instead of silently being written as UTF-8.
    Result := TEncoding.GetEncoding(EncodingIdCodePage(AId));
  end;
end;

// Determines the encoding the file currently has (existing file) or should
// get by default (new file). Existing files are always re-read from disk, so
// changes made outside this server are honoured. A binary Delphi form is only
// replaced when AForce is set, and is then treated as a new file.
procedure ResolveBaseEncoding(const APath: string; AExisting, AForce: Boolean;
  ACache: TEncodingCache; const ARelative: string;
  var AResult: TWriteResult; out ATarget: TTargetEncoding);
var
  LBytes: TBytes;
  LDetected: TDetectedEncoding;
  LSource: TEncodingSource;
  LEntry: TCacheEntry;
  LOverrideId: TEncodingId;
  LUseExisting: Boolean;
begin
  ATarget := Default(TTargetEncoding);
  AResult.PreviousEncodingId := TEncodingId.Unknown;
  LUseExisting := AExisting;
  if AExisting then
  begin
    LBytes := ReadFileBytes(APath);
    if IsBinaryDfm(LBytes) then
    begin
      if not AForce then
        raise EBinaryDfmError.CreateForPath(APath, 'overwrite');
      AddWarning(AResult, Format(
        'The existing file was a binary Delphi form (format "%s") and was replaced ' +
        'with text content because force was set.', [FORMAT_BINARY_DFM]));
      LUseExisting := False;
    end;
  end;
  if LUseExisting then
  begin
    LDetected := ResolveFileEncoding(LBytes, ACache, ARelative, LSource);
    if (Length(LBytes) = 0) and (LSource = TEncodingSource.Detected) then
    begin
      // An empty file carries no encoding information - treat it as new.
      ATarget.Id := TEncodingId.Utf8;
      ATarget.HasBom := True;
      ATarget.LineEnding := TLineEnding.CrLf;
      ATarget.Source := TEncodingSource.Default;
      Exit;
    end;
    AResult.PreviousEncodingId := LDetected.Id;
    ATarget.Id := LDetected.Id;
    ATarget.HasBom := LDetected.HasBom;
    ATarget.LineEnding := LDetected.LineEnding;
    ATarget.Source := LSource;
    if ATarget.LineEnding = TLineEnding.Unknown then
      ATarget.LineEnding := FallbackLineEnding(ACache, ARelative);
  end
  else if ACache.TryGet(ARelative, LEntry) and LEntry.Manual then
  begin
    ATarget.Id := LEntry.EncodingId;
    ATarget.HasBom := IsUnicodeEncoding(ATarget.Id);
    ATarget.LineEnding := TLineEnding.CrLf;
    ATarget.Source := TEncodingSource.ManualOverride;
  end
  else if ACache.TryGetPatternOverride(ARelative, LOverrideId) then
  begin
    ATarget.Id := LOverrideId;
    ATarget.HasBom := IsUnicodeEncoding(ATarget.Id);
    ATarget.LineEnding := TLineEnding.CrLf;
    ATarget.Source := TEncodingSource.PatternOverride;
  end
  else
  begin
    ATarget.Id := TEncodingId.Utf8;
    ATarget.HasBom := True;
    ATarget.LineEnding := TLineEnding.CrLf;
    ATarget.Source := TEncodingSource.Default;
  end;
end;

// Applies explicit caller options and the ASCII upgrade rules on top of the
// base encoding.
procedure ApplyWriteRules(const AContent: string; const AOptions: TWriteOptions;
  var AResult: TWriteResult; var ATarget: TTargetEncoding);
begin
  if AOptions.EncodingOverride <> TEncodingId.Unknown then
  begin
    if not IsUnicodeEncoding(AOptions.EncodingOverride) then
      ATarget.HasBom := False
    else if not IsUnicodeEncoding(ATarget.Id) then
      // Switching from an 8-bit encoding to Unicode: a BOM is required for
      // tools such as Delphi to recognise the file as Unicode.
      ATarget.HasBom := True;
    ATarget.Id := AOptions.EncodingOverride;
    ATarget.Source := TEncodingSource.Explicit;
  end;
  if AOptions.LineEndingOverride <> TLineEnding.Unknown then
    ATarget.LineEnding := AOptions.LineEndingOverride;
  if AOptions.HasBomOverride = 0 then
    ATarget.HasBom := False
  else if AOptions.HasBomOverride = 1 then
    ATarget.HasBom := True;

  if ATarget.Id = TEncodingId.Ascii then
  begin
    if ATarget.HasBom then
    begin
      // ASCII has no BOM; a requested BOM can only mean UTF-8 with BOM.
      AResult.UpgradedFrom := TEncodingId.Ascii;
      ATarget.Id := TEncodingId.Utf8;
      AddWarning(AResult,
        'ASCII cannot carry a BOM; the file was written as UTF-8 with BOM as requested.');
    end
    else if (ATarget.Source = TEncodingSource.Detected) and ContainsNonAscii(AContent) then
    begin
      // Pure ASCII is ambiguous. Never fall back to BOM-less UTF-8, which
      // Delphi and other ANSI tools would misread.
      AResult.UpgradedFrom := TEncodingId.Ascii;
      ATarget.Id := TEncodingId.Windows1252;
      AddWarning(AResult,
        'The file was pure ASCII and the new content contains non-ASCII characters; ' +
        'it was written as Windows-1252 without BOM. Pass encoding "UTF-8" with ' +
        'hasBom true to write UTF-8 instead.');
    end;
  end;

  if ATarget.HasBom and not IsUnicodeEncoding(ATarget.Id) then
  begin
    ATarget.HasBom := False;
    if AOptions.HasBomOverride = 1 then
      AddWarning(AResult, Format('%s cannot carry a BOM; the file was written without BOM.',
        [EncodingIdName(ATarget.Id)]));
  end;
end;

// Keeps the sidecar consistent with what was written and warns when a later
// read would resolve a different encoding.
procedure UpdateCacheAfterWrite(const APath: string; ACache: TEncodingCache;
  const ARelative: string; const ATarget: TTargetEncoding; var AResult: TWriteResult);
var
  LEntry: TCacheEntry;
  LOverrideId: TEncodingId;
  LHasManual: Boolean;
begin
  LHasManual := ACache.TryGet(ARelative, LEntry) and LEntry.Manual;
  if LHasManual then
  begin
    if (not ATarget.HasBom) and (LEntry.EncodingId <> ATarget.Id) then
    begin
      AddWarning(AResult, Format(
        'The per-file override for this file was changed from %s to %s to match the written content.',
        [EncodingIdName(LEntry.EncodingId), EncodingIdName(ATarget.Id)]));
      LEntry.EncodingId := ATarget.Id;
    end;
  end
  else
  begin
    LEntry := Default(TCacheEntry);
    LEntry.EncodingId := ATarget.Id;
    if (not ATarget.HasBom) and ACache.TryGetPatternOverride(ARelative, LOverrideId) and
       (LOverrideId <> ATarget.Id) then
      AddWarning(AResult, Format(
        'A pattern override maps this file to %s, so it will be read as %s, not %s. ' +
        'Write with a BOM or change the override.',
        [EncodingIdName(LOverrideId), EncodingIdName(LOverrideId), EncodingIdName(ATarget.Id)]));
  end;
  LEntry.HasBom := ATarget.HasBom;
  LEntry.LineEnding := ATarget.LineEnding;
  LEntry.DetectedAt := Now;
  LEntry.FileSize := AResult.BytesWritten;
  LEntry.FileTimestamp := TFile.GetLastWriteTime(APath);
  ACache.Put(ARelative, LEntry);
end;

function WriteTextFile(const APath: string; const AContent: string;
  ACacheManager: TCacheManager; const AOptions: TWriteOptions): TWriteResult;
var
  LCache: TEncodingCache;
  LRelative: string;
  LTarget: TTargetEncoding;
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

  ACacheManager.Resolve(APath, LCache, LRelative);
  ResolveBaseEncoding(APath, LExisting, AOptions.Force, LCache, LRelative, Result, LTarget);
  ApplyWriteRules(AContent, AOptions, Result, LTarget);
  Result.Created := not LExisting;

  LContent := NormalizeLineEndings(AContent, LTarget.LineEnding);

  LEncoding := CreateTextEncoding(LTarget.Id);
  try
    LUnsupportedCount := 0;
    if not IsUnicodeEncoding(LTarget.Id) then
    begin
      LUnsupportedCount := CountUnsupportedChars(LContent, LEncoding, LSample);
      if LUnsupportedCount > 0 then
        raise EUnsupportedCharsError.Create(LUnsupportedCount, LSample, LTarget.Id);
    end;
    LBytes := LEncoding.GetBytes(LContent);
    if LTarget.HasBom then
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

  Result.EncodingId := LTarget.Id;
  Result.HasBom := LTarget.HasBom;
  Result.LineEnding := LTarget.LineEnding;
  Result.Source := LTarget.Source;
  Result.BytesWritten := Length(LFinal);
  Result.UnsupportedCharCount := LUnsupportedCount;

  if AOptions.DryRun then
    Exit;

  if not LExisting then
    TDirectory.CreateDirectory(TPath.GetDirectoryName(APath));
  WriteBytesToFile(APath, LFinal);
  UpdateCacheAfterWrite(APath, LCache, LRelative, LTarget, Result);
end;

end.
