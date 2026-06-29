unit FileIO.Reader;

/// <summary>
///   Encoding-aware file reading. Detects encoding (or uses cache),
///   converts to UTF-8 string, and returns metadata.
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
    LineNumberStart: Integer; // 1-based line number of first returned line (0 if empty)
    MatchCount: Integer;      // Number of lines matching searchText (0 if no search)
  end;

/// <summary>
///   Reads a file, detects (or retrieves cached) encoding, and returns
///   the content as a UTF-8 string. The cache is updated with detected encoding.
/// </summary>
/// <param name="APath">Absolute path to the file.</param>
/// <param name="ACacheManager">Cache manager. Must not be nil.</param>
/// <param name="AHead">If &gt; 0, return only the first N lines.</param>
/// <param name="ATail">If &gt; 0, return only the last N lines.</param>
/// <param name="AStartLine">If &gt; 0, return lines starting from this 1-based line number.</param>
/// <param name="AEndLine">If &gt; 0, return lines up to and including this 1-based line number.</param>
/// <param name="AContextLines">Extra lines to include before and after the startLine/endLine range.</param>
/// <param name="ASearchText">If non-empty, return only lines containing this text (case-insensitive) with line numbers.</param>
function ReadTextFile(const APath: string; ACacheManager: TCacheManager;
  AHead: Integer = 0; ATail: Integer = 0;
  AStartLine: Integer = 0; AEndLine: Integer = 0;
  AContextLines: Integer = 0;
  const ASearchText: string = ''): TReadResult;

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

function ApplyHeadTail(const AContent: string; AHead, ATail,
  AStartLine, AEndLine, AContextLines: Integer;
  out ATotalLines, AReturnedLines, ALineNumberStart: Integer): string;
var
  LLines: TArray<string>;
  LStart, LEnd, I: Integer;
  LBuilder: TStringBuilder;
begin
  // Preserve original line endings by splitting manually
  if AContent = '' then
  begin
    ATotalLines := 0;
    AReturnedLines := 0;
    ALineNumberStart := 0;
    Exit('');
  end;
  // Count lines by splitting on LF (CR is handled as part of line content)
  LLines := AContent.Split([#10]);
  ATotalLines := Length(LLines);

  // Priority: startLine/endLine > head > tail
  if (AStartLine > 0) or (AEndLine > 0) then
  begin
    // Convert 1-based to 0-based indices
    if AStartLine > 0 then
      LStart := AStartLine - 1
    else
      LStart := 0;
    if AEndLine > 0 then
      LEnd := AEndLine - 1
    else
      LEnd := ATotalLines - 1;
    // Clamp to valid range
    if LStart >= ATotalLines then
      LStart := ATotalLines - 1;
    if LEnd >= ATotalLines then
      LEnd := ATotalLines - 1;
    // Apply context lines
    if AContextLines > 0 then
    begin
      LStart := LStart - AContextLines;
      LEnd := LEnd + AContextLines;
    end;
    // Clamp again after context expansion
    if LStart < 0 then
      LStart := 0;
    if LEnd >= ATotalLines then
      LEnd := ATotalLines - 1;
    if LStart > LEnd then
    begin
      AReturnedLines := 0;
      ALineNumberStart := 0;
      Exit('');
    end;
  end
  else if (AHead <= 0) and (ATail <= 0) then
  begin
    AReturnedLines := ATotalLines;
    ALineNumberStart := 1;
    Exit(AContent);
  end
  else if (AHead > 0) and (AHead < ATotalLines) then
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
    ALineNumberStart := 1;
    Exit(AContent);
  end;

  ALineNumberStart := LStart + 1; // Convert 0-based back to 1-based
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

/// <summary>
///   Searches content for lines containing ASearchText (case-insensitive).
///   Returns matching lines with line-number prefixes and optional context,
///   separated by '...' between non-contiguous regions.
/// </summary>
function ApplySearch(const AContent, ASearchText: string; AContextLines: Integer;
  out ATotalLines, AReturnedLines, ALineNumberStart, AMatchCount: Integer): string;
var
  LLines: TArray<string>;
  LInclude: TArray<Boolean>;
  LSearchLower: string;
  I, J, LStart, LEnd, LLastIncluded, LLineNumWidth: Integer;
  LBuilder: TStringBuilder;
  LPrevIncluded: Boolean;
begin
  ATotalLines := 0;
  AReturnedLines := 0;
  ALineNumberStart := 0;
  AMatchCount := 0;

  if (AContent = '') or (ASearchText = '') then
    Exit('');

  LLines := AContent.Split([#10]);
  ATotalLines := Length(LLines);
  SetLength(LInclude, ATotalLines);

  // Find matching lines (case-insensitive)
  LSearchLower := ASearchText.ToLower;
  for I := 0 to ATotalLines - 1 do
  begin
    if LLines[I].ToLower.Contains(LSearchLower) then
    begin
      Inc(AMatchCount);
      LStart := Max(0, I - AContextLines);
      LEnd := Min(ATotalLines - 1, I + AContextLines);
      for J := LStart to LEnd do
        LInclude[J] := True;
    end;
  end;

  if AMatchCount = 0 then
    Exit('');

  // Find first/last included line and count returned lines
  LLastIncluded := 0;
  for I := 0 to ATotalLines - 1 do
  begin
    if LInclude[I] then
    begin
      Inc(AReturnedLines);
      if ALineNumberStart = 0 then
        ALineNumberStart := I + 1;
      LLastIncluded := I;
    end;
  end;

  LLineNumWidth := Length(IntToStr(LLastIncluded + 1));

  LBuilder := TStringBuilder.Create;
  try
    LPrevIncluded := False;
    for I := 0 to ATotalLines - 1 do
    begin
      if LInclude[I] then
      begin
        if (not LPrevIncluded) and (LBuilder.Length > 0) then
          LBuilder.Append('...' + #10);
        LBuilder.Append(Format('%*d', [LLineNumWidth, I + 1]));
        LBuilder.Append(#9);
        LBuilder.Append(LLines[I]);
        if I < LLastIncluded then
          LBuilder.Append(#10);
        LPrevIncluded := True;
      end
      else
        LPrevIncluded := False;
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function ReadTextFile(const APath: string; ACacheManager: TCacheManager;
  AHead: Integer; ATail: Integer;
  AStartLine: Integer; AEndLine: Integer;
  AContextLines: Integer;
  const ASearchText: string): TReadResult;
var
  LBytes: TBytes;
  LDetected: TDetectedEncoding;
  LCache: TEncodingCache;
  LRelative: string;
  LEntry: TCacheEntry;
  LHasCached: Boolean;
  LOverrideId: TEncodingId;
  LBom: TBomInfo;
  LFileSize: Int64;
  LFileTimestamp: TDateTime;
begin
  if not TFile.Exists(APath) then
    raise Exception.CreateFmt('File not found: %s', [APath]);
  LBytes := ReadAllBytes(APath);
  LFileSize := Length(LBytes);
  LFileTimestamp := TFile.GetLastWriteTime(APath);
  Result := Default(TReadResult);
  Result.BytesRead := LFileSize;
  Result.FromCache := False;

  ACacheManager.Resolve(APath, LCache, LRelative);
  LHasCached := LCache.TryGet(LRelative, LEntry);

  // Invalidate non-manual cache if file has changed since detection
  if LHasCached and (not LEntry.Manual) and
     ((LEntry.FileSize <> LFileSize) or
      (Abs(LEntry.FileTimestamp - LFileTimestamp) > (1 / SecsPerDay))) then
  begin
    LHasCached := False;
  end;

  // Determine encoding priority:
  //   1) BOM (always 100% certain)
  //   2) Cached manual override (set by user)
  //   3) Extension override from cache (e.g. *.pas → Windows-1252)
  //   4) Cached auto-detected entry if file is unchanged (we re-detect for safety)
  //   5) Fresh detection
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
  if ASearchText <> '' then
    Result.Content := ApplySearch(Result.Content, ASearchText, AContextLines,
      Result.TotalLines, Result.ReturnedLines, Result.LineNumberStart,
      Result.MatchCount)
  else
    Result.Content := ApplyHeadTail(Result.Content, AHead, ATail,
      AStartLine, AEndLine, AContextLines,
      Result.TotalLines, Result.ReturnedLines, Result.LineNumberStart);

  // Update cache (unless there is a manual entry we should not overwrite)
  if not (LHasCached and LEntry.Manual) then
  begin
    LEntry := Default(TCacheEntry);
    LEntry.EncodingId := LDetected.Id;
    LEntry.HasBom := LDetected.HasBom;
    LEntry.LineEnding := LDetected.LineEnding;
    LEntry.Manual := False;
    LEntry.DetectedAt := Now;
    LEntry.FileSize := LFileSize;
    LEntry.FileTimestamp := LFileTimestamp;
    LCache.Put(LRelative, LEntry);
  end;
end;

end.
