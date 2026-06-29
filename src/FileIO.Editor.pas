unit FileIO.Editor;

/// <summary>
///   Encoding-aware text editing. Provides targeted edits (search/replace or
///   line-range replacement) while preserving the original file's encoding,
///   BOM, and line-ending style.
/// </summary>

interface

uses
  System.SysUtils,
  Encoding.Types,
  Encoding.CacheManager;

type
  /// <summary>
  ///   Result of an edit operation.
  /// </summary>
  TEditResult = record
    EncodingId: TEncodingId;
    HasBom: Boolean;
    LineEnding: TLineEnding;
    BytesWritten: Int64;
    Replacements: Integer;
    Changed: Boolean;
    Diff: string;
  end;

  /// <summary>
  ///   Raised when an edit operation cannot be performed safely.
  /// </summary>
  EEditError = class(Exception);

  /// <summary>
  ///   Options controlling how an edit is applied.
  /// </summary>
  TEditOptions = record
    OldText: string;
    NewText: string;
    StartLine: Integer;       // 1-based, 0 = not set
    EndLine: Integer;         // 1-based, 0 = not set, inclusive
    MaxReplacements: Integer; // 0 = unlimited (default 1 for safety)
    DryRun: Boolean;          // If true, compute result without writing
  end;

/// <summary>Returns a default edit options record (MaxReplacements = 1).</summary>
function MakeDefaultEditOptions: TEditOptions;

/// <summary>
///   Edits a text file while preserving its original encoding, BOM, and line endings.
///   Two modes:
///   1. Search/replace: OldText is found and replaced with NewText.
///   2. Range replacement: when StartLine/EndLine are set and OldText is empty,
///      the specified line range is replaced with NewText.
/// </summary>
/// <param name="APath">Absolute path to the file. Must exist.</param>
/// <param name="ACacheManager">Cache manager used for encoding lookup.</param>
/// <param name="AOptions">Edit options describing what to change.</param>
/// <returns>Result record with encoding metadata and replacement count.</returns>
/// <exception cref="EEditError">When no match is found or multiple matches exist with MaxReplacements=1.</exception>
function EditTextFile(const APath: string; ACacheManager: TCacheManager;
  const AOptions: TEditOptions): TEditResult;

/// <summary>
///   Applies multiple edits to a single file atomically. Edits are applied
///   sequentially on in-memory content. If all edits succeed the file is
///   written once. If any edit fails, no changes are written.
/// </summary>
/// <param name="APath">Absolute path to the file. Must exist.</param>
/// <param name="ACacheManager">Cache manager used for encoding lookup.</param>
/// <param name="AEdits">Array of edit options to apply in order.</param>
/// <param name="ADryRun">If true, compute results without writing to disk.</param>
/// <returns>Result record with total replacement count across all edits.</returns>
/// <exception cref="EEditError">When any edit in the array fails.</exception>
function EditTextFileMulti(const APath: string; ACacheManager: TCacheManager;
  const AEdits: TArray<TEditOptions>; ADryRun: Boolean = False): TEditResult;

implementation

uses
  System.Classes,
  System.IOUtils,
  System.DateUtils,
  FileIO.Reader,
  FileIO.Writer;

function MakeDefaultEditOptions: TEditOptions;
begin
  Result.OldText := '';
  Result.NewText := '';
  Result.StartLine := 0;
  Result.EndLine := 0;
  Result.MaxReplacements := 1;
  Result.DryRun := False;
end;

function GenerateDiff(const ABefore, AAfter: string; AContextLines: Integer = 3): string;
var
  LOldLines, LNewLines: TArray<string>;
  LBuilder: TStringBuilder;
  I, J, LMaxCommon, LOldIdx, LNewIdx: Integer;
  LCtxStart, LCtxEnd: Integer;
begin
  if ABefore = AAfter then
    Exit('');
  LOldLines := ABefore.Split([#10]);
  LNewLines := AAfter.Split([#10]);

  // Find first differing line
  LMaxCommon := Length(LOldLines);
  if Length(LNewLines) < LMaxCommon then
    LMaxCommon := Length(LNewLines);
  LOldIdx := 0;
  while (LOldIdx < LMaxCommon) and (LOldLines[LOldIdx] = LNewLines[LOldIdx]) do
    Inc(LOldIdx);

  // Find last differing line (from end)
  I := Length(LOldLines) - 1;
  J := Length(LNewLines) - 1;
  while (I >= LOldIdx) and (J >= LOldIdx) and (LOldLines[I] = LNewLines[J]) do
  begin
    Dec(I);
    Dec(J);
  end;
  // I = last changed old line index, J = last changed new line index

  LBuilder := TStringBuilder.Create;
  try
    // Context start
    LCtxStart := LOldIdx - AContextLines;
    if LCtxStart < 0 then LCtxStart := 0;
    LCtxEnd := I + AContextLines;
    if LCtxEnd >= Length(LOldLines) then LCtxEnd := Length(LOldLines) - 1;

    // Hunk header
    LBuilder.AppendFormat('@@ -%d,%d +%d,%d @@',
      [LCtxStart + 1, LCtxEnd - LCtxStart + 1,
       LCtxStart + 1, (LCtxEnd - LCtxStart + 1) - (I - LOldIdx + 1) + (J - LOldIdx + 1)]);
    LBuilder.Append(#10);

    // Context before
    for LNewIdx := LCtxStart to LOldIdx - 1 do
    begin
      LBuilder.Append(' ');
      LBuilder.Append(LOldLines[LNewIdx]);
      LBuilder.Append(#10);
    end;

    // Removed lines (old)
    for LNewIdx := LOldIdx to I do
    begin
      LBuilder.Append('-');
      LBuilder.Append(LOldLines[LNewIdx]);
      LBuilder.Append(#10);
    end;

    // Added lines (new)
    for LNewIdx := LOldIdx to J do
    begin
      LBuilder.Append('+');
      LBuilder.Append(LNewLines[LNewIdx]);
      LBuilder.Append(#10);
    end;

    // Context after
    for LNewIdx := I + 1 to LCtxEnd do
    begin
      LBuilder.Append(' ');
      LBuilder.Append(LOldLines[LNewIdx]);
      LBuilder.Append(#10);
    end;

    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function CountOccurrences(const AText, APattern: string): Integer;
var
  LPos, LLen: Integer;
begin
  Result := 0;
  if APattern = '' then
    Exit;
  LLen := Length(APattern);
  LPos := Pos(APattern, AText);
  while LPos > 0 do
  begin
    Inc(Result);
    LPos := Pos(APattern, AText, LPos + LLen);
  end;
end;

function ReplaceN(const AText, AOld, ANew: string; AMax: Integer;
  out ACount: Integer): string;
var
  LPos, LLen, LSearchFrom: Integer;
  LBuilder: TStringBuilder;
begin
  ACount := 0;
  if AOld = '' then
    Exit(AText);
  LLen := Length(AOld);
  LBuilder := TStringBuilder.Create(Length(AText));
  try
    LSearchFrom := 1;
    while LSearchFrom <= Length(AText) do
    begin
      LPos := Pos(AOld, AText, LSearchFrom);
      if (LPos = 0) or ((AMax > 0) and (ACount >= AMax)) then
      begin
        LBuilder.Append(Copy(AText, LSearchFrom, MaxInt));
        Break;
      end;
      LBuilder.Append(Copy(AText, LSearchFrom, LPos - LSearchFrom));
      LBuilder.Append(ANew);
      Inc(ACount);
      LSearchFrom := LPos + LLen;
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function ApplyRangeReplace(const AContent, ANewText: string;
  AStartLine, AEndLine: Integer): string;
var
  LLines: TArray<string>;
  LStartIdx, LEndIdx, I, LTotal: Integer;
  LBuilder: TStringBuilder;
begin
  if AContent = '' then
  begin
    if (AStartLine > 1) or (AEndLine > 1) then
      raise EEditError.Create('Range is beyond the empty file');
    Exit(ANewText);
  end;

  LLines := AContent.Split([#10]);
  LTotal := Length(LLines);

  // Convert 1-based to 0-based, clamp
  LStartIdx := 0;
  if AStartLine > 0 then
    LStartIdx := AStartLine - 1;
  if LStartIdx >= LTotal then
    LStartIdx := LTotal - 1;

  LEndIdx := LTotal - 1;
  if AEndLine > 0 then
    LEndIdx := AEndLine - 1;
  if LEndIdx >= LTotal then
    LEndIdx := LTotal - 1;

  if LStartIdx > LEndIdx then
    raise EEditError.CreateFmt(
      'Invalid range: startLine %d > endLine %d', [AStartLine, AEndLine]);

  LBuilder := TStringBuilder.Create;
  try
    // Lines before the range
    for I := 0 to LStartIdx - 1 do
    begin
      LBuilder.Append(LLines[I]);
      LBuilder.Append(#10);
    end;
    // Insert new text
    LBuilder.Append(ANewText);
    // Lines after the range
    if LEndIdx < LTotal - 1 then
    begin
      LBuilder.Append(#10);
      for I := LEndIdx + 1 to LTotal - 1 do
      begin
        LBuilder.Append(LLines[I]);
        if I < LTotal - 1 then
          LBuilder.Append(#10);
      end;
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function EditTextFile(const APath: string; ACacheManager: TCacheManager;
  const AOptions: TEditOptions): TEditResult;
var
  LReadResult: TReadResult;
  LContent, LModified: string;
  LWriteOptions: TWriteOptions;
  LWriteResult: TWriteResult;
  LMatchCount, LReplacements: Integer;
  LIsRangeMode: Boolean;
  LTimestampAtRead: TDateTime;
begin
  Result := Default(TEditResult);

  // Read with encoding detection and capture timestamp for optimistic lock
  LTimestampAtRead := TFile.GetLastWriteTime(APath);
  LReadResult := ReadTextFile(APath, ACacheManager);
  LContent := LReadResult.Content;

  LIsRangeMode := (AOptions.OldText = '') and
    ((AOptions.StartLine > 0) or (AOptions.EndLine > 0));

  if LIsRangeMode then
  begin
    // Mode 2: Range replacement
    LModified := ApplyRangeReplace(LContent, AOptions.NewText,
      AOptions.StartLine, AOptions.EndLine);
    LReplacements := 1;
  end
  else
  begin
    // Mode 1: Search/replace
    if AOptions.OldText = '' then
      raise EEditError.Create('Either oldText or startLine/endLine must be provided');

    LMatchCount := CountOccurrences(LContent, AOptions.OldText);
    if LMatchCount = 0 then
      raise EEditError.Create('No match found for oldText');

    if (AOptions.MaxReplacements = 1) and (LMatchCount > 1) then
      raise EEditError.CreateFmt(
        'Found %d matches for oldText but maxReplacements is 1. ' +
        'Provide more context in oldText or increase maxReplacements.',
        [LMatchCount]);

    LModified := ReplaceN(LContent, AOptions.OldText, AOptions.NewText,
      AOptions.MaxReplacements, LReplacements);
  end;

  Result.Changed := LModified <> LContent;
  Result.Replacements := LReplacements;
  if Result.Changed then
    Result.Diff := GenerateDiff(LContent, LModified);

  if (not Result.Changed) or AOptions.DryRun then
  begin
    // Nothing to write (unchanged or dry run)
    Result.EncodingId := LReadResult.EncodingId;
    Result.HasBom := LReadResult.HasBom;
    Result.LineEnding := LReadResult.LineEnding;
    Result.BytesWritten := LReadResult.BytesRead;
    Exit;
  end;

  // Optimistic lock: verify file unchanged since read
  if Abs(TFile.GetLastWriteTime(APath) - LTimestampAtRead) > (1 / SecsPerDay) then
    raise EEditError.Create(
      'File was modified by another process since it was read. Edit aborted.');

  // Write back preserving encoding
  LWriteOptions := MakeDefaultWriteOptions;
  LWriteResult := WriteTextFile(APath, LModified, ACacheManager, LWriteOptions);

  Result.EncodingId := LWriteResult.EncodingId;
  Result.HasBom := LWriteResult.HasBom;
  Result.LineEnding := LWriteResult.LineEnding;
  Result.BytesWritten := LWriteResult.BytesWritten;
end;

function EditTextFileMulti(const APath: string; ACacheManager: TCacheManager;
  const AEdits: TArray<TEditOptions>; ADryRun: Boolean): TEditResult;
var
  LReadResult: TReadResult;
  LContent, LModified: string;
  LWriteOptions: TWriteOptions;
  LWriteResult: TWriteResult;
  LMatchCount, LReplacements, LTotalReplacements: Integer;
  LIsRangeMode: Boolean;
  LTimestampAtRead: TDateTime;
  I: Integer;
begin
  Result := Default(TEditResult);

  if Length(AEdits) = 0 then
    raise EEditError.Create('Edits array must not be empty');

  // Read file once and capture timestamp for optimistic lock
  LTimestampAtRead := TFile.GetLastWriteTime(APath);
  LReadResult := ReadTextFile(APath, ACacheManager);
  LContent := LReadResult.Content;
  LTotalReplacements := 0;

  // Apply each edit sequentially on in-memory content
  for I := 0 to Length(AEdits) - 1 do
  begin
    LIsRangeMode := (AEdits[I].OldText = '') and
      ((AEdits[I].StartLine > 0) or (AEdits[I].EndLine > 0));

    if LIsRangeMode then
    begin
      LContent := ApplyRangeReplace(LContent, AEdits[I].NewText,
        AEdits[I].StartLine, AEdits[I].EndLine);
      Inc(LTotalReplacements);
    end
    else
    begin
      if AEdits[I].OldText = '' then
        raise EEditError.CreateFmt(
          'Edit %d: either oldText or startLine/endLine must be provided', [I + 1]);

      LMatchCount := CountOccurrences(LContent, AEdits[I].OldText);
      if LMatchCount = 0 then
        raise EEditError.CreateFmt(
          'Edit %d: no match found for oldText', [I + 1]);

      if (AEdits[I].MaxReplacements = 1) and (LMatchCount > 1) then
        raise EEditError.CreateFmt(
          'Edit %d: found %d matches for oldText but maxReplacements is 1. ' +
          'Provide more context or increase maxReplacements.', [I + 1, LMatchCount]);

      LModified := ReplaceN(LContent, AEdits[I].OldText, AEdits[I].NewText,
        AEdits[I].MaxReplacements, LReplacements);
      LContent := LModified;
      Inc(LTotalReplacements, LReplacements);
    end;
  end;

  Result.Changed := LContent <> LReadResult.Content;
  Result.Replacements := LTotalReplacements;
  if Result.Changed then
    Result.Diff := GenerateDiff(LReadResult.Content, LContent);

  if (not Result.Changed) or ADryRun then
  begin
    Result.EncodingId := LReadResult.EncodingId;
    Result.HasBom := LReadResult.HasBom;
    Result.LineEnding := LReadResult.LineEnding;
    Result.BytesWritten := LReadResult.BytesRead;
    Exit;
  end;

  // Optimistic lock: verify file unchanged since read
  if Abs(TFile.GetLastWriteTime(APath) - LTimestampAtRead) > (1 / SecsPerDay) then
    raise EEditError.Create(
      'File was modified by another process since it was read. Edit aborted.');

  // Write back preserving encoding - single write for all edits
  LWriteOptions := MakeDefaultWriteOptions;
  LWriteResult := WriteTextFile(APath, LContent, ACacheManager, LWriteOptions);

  Result.EncodingId := LWriteResult.EncodingId;
  Result.HasBom := LWriteResult.HasBom;
  Result.LineEnding := LWriteResult.LineEnding;
  Result.BytesWritten := LWriteResult.BytesWritten;
end;

end.
