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
    UpgradedFrom: TEncodingId;     // Set when the write had to upgrade the encoding
    Warnings: TArray<string>;      // Warnings reported by the writer
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
///      the inclusive line range is replaced with NewText. An empty NewText
///      deletes the lines including their line terminators. StartLine may be
///      one past the last line to append text.
///   Line breaks in OldText and NewText are converted to the file's dominant
///   line-ending style (also for Mixed files) before matching and inserting.
/// </summary>
/// <param name="APath">Absolute path to the file. Must exist.</param>
/// <param name="ACacheManager">Cache manager used for encoding lookup.</param>
/// <param name="AOptions">Edit options describing what to change.</param>
/// <returns>Result record with encoding metadata, replacement count and a
///   unified diff with one hunk per changed region.</returns>
/// <exception cref="EEditError">When no match is found, multiple matches exist
///   with MaxReplacements=1, or the line range is invalid.</exception>
function EditTextFile(const APath: string; ACacheManager: TCacheManager;
  const AOptions: TEditOptions): TEditResult;

/// <summary>
///   Applies multiple edits to a single file atomically. All StartLine/EndLine
///   values refer to the original file: range edits are validated against it,
///   overlapping ranges are rejected, and the ranges are applied from the end
///   of the file so earlier line numbers stay valid. Search/replace edits are
///   then applied in array order on the result; a search/replace edit whose
///   matches were created or removed by a range edit is rejected as ambiguous.
///   If any edit fails, no changes are written.
/// </summary>
/// <param name="APath">Absolute path to the file. Must exist.</param>
/// <param name="ACacheManager">Cache manager used for encoding lookup.</param>
/// <param name="AEdits">Array of edit options.</param>
/// <param name="ADryRun">If true, compute results without writing to disk.</param>
/// <returns>Result record with total replacement count across all edits.</returns>
/// <exception cref="EEditError">When any edit in the array fails.</exception>
function EditTextFileMulti(const APath: string; ACacheManager: TCacheManager;
  const AEdits: TArray<TEditOptions>; ADryRun: Boolean = False): TEditResult;

implementation

uses
  System.IOUtils,
  System.Math,
  System.Generics.Collections,
  System.Generics.Defaults,
  Encoding.Cache,
  FileIO.Reader,
  FileIO.Writer;

type
  // A line together with its own terminator; LineBreak is '' only for a last
  // line that is not terminated. Keeping the terminator per line lets edits
  // and diffs handle CRLF, LF, CR and Mixed files without guessing.
  TTextLine = record
    Text: string;
    LineBreak: string;
  end;

  TDiffOp = (Equal, Delete, Insert);

  // One step of a line diff. OldIndex/NewIndex are 0-based positions; for an
  // Insert OldIndex is the old position it is inserted at, for a Delete
  // NewIndex is the corresponding new position.
  TDiffStep = record
    Op: TDiffOp;
    OldIndex: Integer;
    NewIndex: Integer;
  end;

  // A range edit resolved against the original file (0-based, inclusive).
  // LastIdx = FirstIdx - 1 marks a pure insertion (append at end of file).
  TResolvedRange = record
    EditIndex: Integer;
    FirstIdx: Integer;
    LastIdx: Integer;
    NewText: string;
  end;

const
  DIFF_CONTEXT_LINES = 3;
  // Beyond this many differing lines the diff falls back to one replace
  // block, which bounds time and memory of the Myers algorithm.
  DIFF_MAX_EDIT_DISTANCE = 2000;

function MakeDefaultEditOptions: TEditOptions;
begin
  Result.OldText := '';
  Result.NewText := '';
  Result.StartLine := 0;
  Result.EndLine := 0;
  Result.MaxReplacements := 1;
  Result.DryRun := False;
end;

function SplitLines(const AContent: string): TArray<TTextLine>;
var
  LList: TList<TTextLine>;
  LLine: TTextLine;
  I, LStart: Integer;
begin
  LList := TList<TTextLine>.Create;
  try
    LStart := 1;
    I := 1;
    while I <= Length(AContent) do
    begin
      if (AContent[I] = #13) or (AContent[I] = #10) then
      begin
        LLine.Text := Copy(AContent, LStart, I - LStart);
        if (AContent[I] = #13) and (I < Length(AContent)) and (AContent[I + 1] = #10) then
        begin
          LLine.LineBreak := #13#10;
          Inc(I);
        end
        else
          LLine.LineBreak := AContent[I];
        LList.Add(LLine);
        Inc(I);
        LStart := I;
      end
      else
        Inc(I);
    end;
    if LStart <= Length(AContent) then
    begin
      LLine.Text := Copy(AContent, LStart, MaxInt);
      LLine.LineBreak := '';
      LList.Add(LLine);
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

function JoinLines(const ALines: TArray<TTextLine>): string;
var
  LBuilder: TStringBuilder;
  LLine: TTextLine;
begin
  LBuilder := TStringBuilder.Create;
  try
    for LLine in ALines do
    begin
      LBuilder.Append(LLine.Text);
      LBuilder.Append(LLine.LineBreak);
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

// The most frequent terminator style; ties prefer CRLF, then LF. Mixed files
// thereby get a definite style for inserted text instead of raw caller input.
function DominantLineEnding(const ALines: TArray<TTextLine>): TLineEnding;
var
  LLine: TTextLine;
  LCrLf, LLf, LCr: Integer;
begin
  LCrLf := 0;
  LLf := 0;
  LCr := 0;
  for LLine in ALines do
    if LLine.LineBreak = #13#10 then
      Inc(LCrLf)
    else if LLine.LineBreak = #10 then
      Inc(LLf)
    else if LLine.LineBreak = #13 then
      Inc(LCr);
  if (LCrLf = 0) and (LLf = 0) and (LCr = 0) then
    Result := TLineEnding.Unknown
  else if (LCrLf >= LLf) and (LCrLf >= LCr) then
    Result := TLineEnding.CrLf
  else if LLf >= LCr then
    Result := TLineEnding.Lf
  else
    Result := TLineEnding.Cr;
end;

function LineBreakText(AStyle: TLineEnding): string;
begin
  case AStyle of
    TLineEnding.CrLf: Result := #13#10;
    TLineEnding.Lf: Result := #10;
    TLineEnding.Cr: Result := #13;
  else
    Result := '';
  end;
end;

function LineBreakName(const ABreak: string): string;
begin
  if ABreak = #13#10 then
    Result := 'CRLF'
  else if ABreak = #10 then
    Result := 'LF'
  else
    Result := 'CR';
end;

function LinesEqual(const A, B: TTextLine): Boolean; inline;
begin
  Result := (A.Text = B.Text) and (A.LineBreak = B.LineBreak);
end;

function MakeStep(AOp: TDiffOp; AOldIndex, ANewIndex: Integer): TDiffStep;
begin
  Result.Op := AOp;
  Result.OldIndex := AOldIndex;
  Result.NewIndex := ANewIndex;
end;

// Myers' O((N+M)D) shortest edit script for the differing middle part.
// Falls back to "delete all, insert all" when the edit distance exceeds
// DIFF_MAX_EDIT_DISTANCE.
procedure DiffMiddle(const AOld, ANew: TArray<TTextLine>;
  AOldStart, AOldCount, ANewStart, ANewCount: Integer; ASteps: TList<TDiffStep>);
var
  LV, LSnap: TArray<Integer>;
  LTrace: TList<TArray<Integer>>;
  LReverse: TList<TDiffStep>;
  LMax, LLimit, LOffset, D, K, X, Y, LPrevK, LPrevX, LPrevY, I: Integer;
  LFound: Boolean;
begin
  if (AOldCount = 0) or (ANewCount = 0) then
  begin
    for I := 0 to AOldCount - 1 do
      ASteps.Add(MakeStep(TDiffOp.Delete, AOldStart + I, ANewStart));
    for I := 0 to ANewCount - 1 do
      ASteps.Add(MakeStep(TDiffOp.Insert, AOldStart + AOldCount, ANewStart + I));
    Exit;
  end;
  LMax := AOldCount + ANewCount;
  LLimit := Min(LMax, DIFF_MAX_EDIT_DISTANCE);
  LOffset := LMax + 1;
  SetLength(LV, 2 * LMax + 3);
  LFound := False;
  LTrace := TList<TArray<Integer>>.Create;
  try
    for D := 0 to LLimit do
    begin
      // Snapshot of V before step D for k in [-(D+1)..D+1], used to backtrack
      LTrace.Add(Copy(LV, LOffset - D - 1, 2 * D + 3));
      K := -D;
      while K <= D do
      begin
        if (K = -D) or ((K <> D) and (LV[LOffset + K - 1] < LV[LOffset + K + 1])) then
          X := LV[LOffset + K + 1]
        else
          X := LV[LOffset + K - 1] + 1;
        Y := X - K;
        while (X < AOldCount) and (Y < ANewCount) and
          LinesEqual(AOld[AOldStart + X], ANew[ANewStart + Y]) do
        begin
          Inc(X);
          Inc(Y);
        end;
        LV[LOffset + K] := X;
        if (X >= AOldCount) and (Y >= ANewCount) then
        begin
          LFound := True;
          Break;
        end;
        Inc(K, 2);
      end;
      if LFound then
        Break;
    end;

    if not LFound then
    begin
      for I := 0 to AOldCount - 1 do
        ASteps.Add(MakeStep(TDiffOp.Delete, AOldStart + I, ANewStart));
      for I := 0 to ANewCount - 1 do
        ASteps.Add(MakeStep(TDiffOp.Insert, AOldStart + AOldCount, ANewStart + I));
      Exit;
    end;

    LReverse := TList<TDiffStep>.Create;
    try
      X := AOldCount;
      Y := ANewCount;
      for D := LTrace.Count - 1 downto 0 do
      begin
        LSnap := LTrace[D];
        K := X - Y;
        if (K = -D) or ((K <> D) and (LSnap[K + D] < LSnap[K + D + 2])) then
          LPrevK := K + 1
        else
          LPrevK := K - 1;
        LPrevX := LSnap[LPrevK + D + 1];
        LPrevY := LPrevX - LPrevK;
        while (X > LPrevX) and (Y > LPrevY) do
        begin
          Dec(X);
          Dec(Y);
          LReverse.Add(MakeStep(TDiffOp.Equal, AOldStart + X, ANewStart + Y));
        end;
        if D > 0 then
        begin
          if X = LPrevX then
            LReverse.Add(MakeStep(TDiffOp.Insert, AOldStart + X, ANewStart + LPrevY))
          else
            LReverse.Add(MakeStep(TDiffOp.Delete, AOldStart + LPrevX, ANewStart + Y));
        end;
        X := LPrevX;
        Y := LPrevY;
      end;
      for I := LReverse.Count - 1 downto 0 do
        ASteps.Add(LReverse[I]);
    finally
      LReverse.Free;
    end;
  finally
    LTrace.Free;
  end;
end;

function ComputeLineDiff(const AOld, ANew: TArray<TTextLine>): TArray<TDiffStep>;
var
  LSteps: TList<TDiffStep>;
  LPrefix, LSuffix, LOldCount, LNewCount, I: Integer;
begin
  LOldCount := Length(AOld);
  LNewCount := Length(ANew);
  LPrefix := 0;
  while (LPrefix < LOldCount) and (LPrefix < LNewCount) and
    LinesEqual(AOld[LPrefix], ANew[LPrefix]) do
    Inc(LPrefix);
  LSuffix := 0;
  while (LSuffix < LOldCount - LPrefix) and (LSuffix < LNewCount - LPrefix) and
    LinesEqual(AOld[LOldCount - 1 - LSuffix], ANew[LNewCount - 1 - LSuffix]) do
    Inc(LSuffix);
  LSteps := TList<TDiffStep>.Create;
  try
    for I := 0 to LPrefix - 1 do
      LSteps.Add(MakeStep(TDiffOp.Equal, I, I));
    DiffMiddle(AOld, ANew, LPrefix, LOldCount - LPrefix - LSuffix,
      LPrefix, LNewCount - LPrefix - LSuffix, LSteps);
    for I := 0 to LSuffix - 1 do
      LSteps.Add(MakeStep(TDiffOp.Equal, LOldCount - LSuffix + I, LNewCount - LSuffix + I));
    Result := LSteps.ToArray;
  finally
    LSteps.Free;
  end;
end;

// Line text for the diff. Lines are always separated by LF in the diff; a
// terminator that differs from the file's style is shown as [CRLF]/[LF]/[CR],
// so the diff states unambiguously what is written to disk.
procedure AppendDiffLine(ABuilder: TStringBuilder; APrefix: Char;
  const ALine: TTextLine; const AExpectedBreak: string);
begin
  ABuilder.Append(APrefix);
  ABuilder.Append(ALine.Text);
  if (ALine.LineBreak <> '') and (ALine.LineBreak <> AExpectedBreak) then
    ABuilder.Append(' [').Append(LineBreakName(ALine.LineBreak)).Append(']');
  ABuilder.Append(#10);
  if ALine.LineBreak = '' then
    ABuilder.Append('\ No newline at end of file'#10);
end;

function GenerateDiff(const ABefore, AAfter: string): string;
var
  LOld, LNew: TArray<TTextLine>;
  LSteps: TArray<TDiffStep>;
  LBuilder: TStringBuilder;
  LExpected: string;
  I, J, LLastChange, LHunkStart, LHunkEnd, LOldCount, LNewCount: Integer;
  LOldStart, LNewStart: Integer;
begin
  if ABefore = AAfter then
    Exit('');
  LOld := SplitLines(ABefore);
  LNew := SplitLines(AAfter);
  LExpected := LineBreakText(DominantLineEnding(LOld));
  if LExpected = '' then
    LExpected := LineBreakText(DominantLineEnding(LNew));
  LSteps := ComputeLineDiff(LOld, LNew);

  LBuilder := TStringBuilder.Create;
  try
    I := 0;
    while I < Length(LSteps) do
    begin
      if LSteps[I].Op = TDiffOp.Equal then
      begin
        Inc(I);
        Continue;
      end;
      // Extend the hunk while the gap between changes is at most two
      // context blocks; larger gaps start a separate hunk.
      LLastChange := I;
      J := I;
      while J < Length(LSteps) do
      begin
        if LSteps[J].Op <> TDiffOp.Equal then
          LLastChange := J
        else if J - LLastChange > 2 * DIFF_CONTEXT_LINES then
          Break;
        Inc(J);
      end;
      LHunkStart := Max(0, I - DIFF_CONTEXT_LINES);
      LHunkEnd := Min(Length(LSteps) - 1, LLastChange + DIFF_CONTEXT_LINES);

      LOldCount := 0;
      LNewCount := 0;
      for J := LHunkStart to LHunkEnd do
      begin
        if LSteps[J].Op <> TDiffOp.Insert then
          Inc(LOldCount);
        if LSteps[J].Op <> TDiffOp.Delete then
          Inc(LNewCount);
      end;
      // Unified diff convention: an empty side names the line before it
      LOldStart := LSteps[LHunkStart].OldIndex;
      if LOldCount > 0 then
        Inc(LOldStart);
      LNewStart := LSteps[LHunkStart].NewIndex;
      if LNewCount > 0 then
        Inc(LNewStart);
      LBuilder.AppendFormat('@@ -%d,%d +%d,%d @@',
        [LOldStart, LOldCount, LNewStart, LNewCount]);
      LBuilder.Append(#10);

      for J := LHunkStart to LHunkEnd do
        case LSteps[J].Op of
          TDiffOp.Equal:
            AppendDiffLine(LBuilder, ' ', LOld[LSteps[J].OldIndex], LExpected);
          TDiffOp.Delete:
            AppendDiffLine(LBuilder, '-', LOld[LSteps[J].OldIndex], LExpected);
          TDiffOp.Insert:
            AppendDiffLine(LBuilder, '+', LNew[LSteps[J].NewIndex], LExpected);
        end;
      I := LHunkEnd + 1;
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

function IsRangeEdit(const AEdit: TEditOptions): Boolean;
begin
  Result := (AEdit.OldText = '') and ((AEdit.StartLine > 0) or (AEdit.EndLine > 0));
end;

// Error prefix that identifies the edit in multi-edit calls only, so the
// single-edit messages stay unchanged.
function EditLabel(AIndex, ACount: Integer): string;
begin
  if ACount > 1 then
    Result := Format('Edit %d: ', [AIndex + 1])
  else
    Result := '';
end;

function ResolveRange(const AEdit: TEditOptions; AIndex, AEditCount,
  ALineCount: Integer): TResolvedRange;
var
  LStart, LEnd: Integer;
begin
  Result.EditIndex := AIndex;
  Result.NewText := AEdit.NewText;
  LStart := Max(AEdit.StartLine, 1);
  if LStart > ALineCount + 1 then
    raise EEditError.CreateFmt(
      '%sstartLine %d is beyond the end of the file (%d lines)',
      [EditLabel(AIndex, AEditCount), LStart, ALineCount]);
  if LStart = ALineCount + 1 then
  begin
    // One past the last line: append at the end of the file
    Result.FirstIdx := ALineCount;
    Result.LastIdx := ALineCount - 1;
    Exit;
  end;
  LEnd := AEdit.EndLine;
  if (LEnd <= 0) or (LEnd > ALineCount) then
    LEnd := ALineCount;
  if LStart > LEnd then
    raise EEditError.CreateFmt('%sInvalid range: startLine %d > endLine %d',
      [EditLabel(AIndex, AEditCount), AEdit.StartLine, AEdit.EndLine]);
  Result.FirstIdx := LStart - 1;
  Result.LastIdx := LEnd - 1;
end;

function RangeText(const ARange: TResolvedRange): string;
begin
  if ARange.LastIdx < ARange.FirstIdx then
    Result := 'append at end of file'
  else
    Result := Format('lines %d-%d', [ARange.FirstIdx + 1, ARange.LastIdx + 1]);
end;

// Sorts the ranges from the end of the file towards the start and rejects
// overlaps, including two insertions at the same position whose relative
// order would be ambiguous.
procedure SortAndCheckRanges(ARanges: TList<TResolvedRange>);
var
  I: Integer;
  LLater, LEarlier: TResolvedRange;
begin
  ARanges.Sort(TComparer<TResolvedRange>.Construct(
    function(const L, R: TResolvedRange): Integer
    begin
      Result := R.FirstIdx - L.FirstIdx;
      if Result = 0 then
        Result := L.EditIndex - R.EditIndex;
    end));
  for I := 1 to ARanges.Count - 1 do
  begin
    LLater := ARanges[I - 1];
    LEarlier := ARanges[I];
    if (LEarlier.FirstIdx = LLater.FirstIdx) or (LEarlier.LastIdx >= LLater.FirstIdx) then
      raise EEditError.CreateFmt(
        'Edits %d and %d overlap (%s and %s). All startLine/endLine values refer ' +
        'to the original file; combine overlapping ranges into one edit.',
        [Min(LEarlier.EditIndex, LLater.EditIndex) + 1,
         Max(LEarlier.EditIndex, LLater.EditIndex) + 1,
         RangeText(LEarlier), RangeText(LLater)]);
  end;
end;

procedure ApplyRange(ALines: TList<TTextLine>; const ARange: TResolvedRange;
  AStyle: TLineEnding);
var
  LNew: TArray<TTextLine>;
  LTrailingBreak, LDefaultBreak: string;
  LPrevious: TTextLine;
begin
  LNew := SplitLines(NormalizeLineEndings(ARange.NewText, AStyle));
  if ARange.LastIdx >= ARange.FirstIdx then
  begin
    LTrailingBreak := ALines[ARange.LastIdx].LineBreak;
    ALines.DeleteRange(ARange.FirstIdx, ARange.LastIdx - ARange.FirstIdx + 1);
  end
  else
    LTrailingBreak := '';
  // Empty NewText deletes the range completely, terminators included
  if Length(LNew) = 0 then
    Exit;
  // The replaced block keeps its terminator, so replacing the last line keeps
  // whether the file ends with a line break and no blank line is added.
  if LNew[High(LNew)].LineBreak = '' then
    LNew[High(LNew)].LineBreak := LTrailingBreak;
  if (ARange.FirstIdx > 0) and (ALines[ARange.FirstIdx - 1].LineBreak = '') then
  begin
    // Appending after an unterminated last line: terminate it first
    LDefaultBreak := LineBreakText(AStyle);
    if LDefaultBreak = '' then
      LDefaultBreak := LNew[0].LineBreak;
    if LDefaultBreak = '' then
      LDefaultBreak := sLineBreak;
    LPrevious := ALines[ARange.FirstIdx - 1];
    LPrevious.LineBreak := LDefaultBreak;
    ALines[ARange.FirstIdx - 1] := LPrevious;
  end;
  ALines.InsertRange(ARange.FirstIdx, LNew);
end;

// True if any range edit removes or inserts text containing APattern. A
// count comparison alone misses a range that deletes one match and inserts
// another, which would let the search/replace silently hit the new text.
function RangesTouch(ARanges: TList<TResolvedRange>;
  const ALines: TArray<TTextLine>; const APattern: string): Boolean;
var
  LRange: TResolvedRange;
  I: Integer;
  LRemoved: TStringBuilder;
begin
  LRemoved := TStringBuilder.Create;
  try
    for LRange in ARanges do
    begin
      if Pos(APattern, LRange.NewText) > 0 then
        Exit(True);
      LRemoved.Clear;
      for I := LRange.FirstIdx to LRange.LastIdx do
        LRemoved.Append(ALines[I].Text).Append(ALines[I].LineBreak);
      if Pos(APattern, LRemoved.ToString) > 0 then
        Exit(True);
    end;
    Result := False;
  finally
    LRemoved.Free;
  end;
end;

// Applies all edits to the in-memory content. Range edits refer to the
// original content and are applied from the end; search/replace edits run
// afterwards in array order. AFallbackStyle is used when the content has no
// line break of its own, so inserted text gets the style the writer will use.
function ApplyEdits(const AContent: string; const AEdits: TArray<TEditOptions>;
  AFallbackStyle: TLineEnding; out AReplacements: Integer): string;
var
  LLines: TArray<TTextLine>;
  LStyle: TLineEnding;
  LRanges: TList<TResolvedRange>;
  LWork: TList<TTextLine>;
  LAfterRanges, LOld, LNew: string;
  I, LCount, LReplacements: Integer;
begin
  AReplacements := 0;
  LLines := SplitLines(AContent);
  LStyle := DominantLineEnding(LLines);
  if LStyle = TLineEnding.Unknown then
    LStyle := AFallbackStyle;

  LRanges := TList<TResolvedRange>.Create;
  try
    for I := 0 to High(AEdits) do
      if (AEdits[I].OldText <> '') and
         ((AEdits[I].StartLine > 0) or (AEdits[I].EndLine > 0)) then
        raise EEditError.CreateFmt(
          '%soldText and startLine/endLine are mutually exclusive; use one mode per edit',
          [EditLabel(I, Length(AEdits))])
      else if IsRangeEdit(AEdits[I]) then
        LRanges.Add(ResolveRange(AEdits[I], I, Length(AEdits), Length(LLines)))
      else if AEdits[I].OldText = '' then
        raise EEditError.CreateFmt('%sEither oldText or startLine/endLine must be provided',
          [EditLabel(I, Length(AEdits))]);
    SortAndCheckRanges(LRanges);

    LWork := TList<TTextLine>.Create;
    try
      LWork.AddRange(LLines);
      for I := 0 to LRanges.Count - 1 do
        ApplyRange(LWork, LRanges[I], LStyle);
      LAfterRanges := JoinLines(LWork.ToArray);
    finally
      LWork.Free;
    end;
    Inc(AReplacements, LRanges.Count);

    Result := LAfterRanges;
    for I := 0 to High(AEdits) do
    begin
      if IsRangeEdit(AEdits[I]) then
        Continue;
      // Match with the file's line breaks first; fall back to the text as
      // given for regions of a Mixed file that use another style.
      LOld := NormalizeLineEndings(AEdits[I].OldText, LStyle);
      if (LOld <> AEdits[I].OldText) and (CountOccurrences(Result, LOld) = 0) then
        LOld := AEdits[I].OldText;
      if (LRanges.Count > 0) and
         ((CountOccurrences(AContent, LOld) <> CountOccurrences(LAfterRanges, LOld)) or
          RangesTouch(LRanges, LLines, LOld)) then
        raise EEditError.CreateFmt(
          '%sAmbiguous order: the line-range edits in this call create or remove ' +
          'matches for oldText. Split the call or use only one kind of edit.',
          [EditLabel(I, Length(AEdits))]);
      LCount := CountOccurrences(Result, LOld);
      if LCount = 0 then
        raise EEditError.CreateFmt('%sNo match found for oldText',
          [EditLabel(I, Length(AEdits))]);
      if (AEdits[I].MaxReplacements = 1) and (LCount > 1) then
        raise EEditError.CreateFmt(
          '%sFound %d matches for oldText but maxReplacements is 1. ' +
          'Provide more context in oldText or increase maxReplacements.',
          [EditLabel(I, Length(AEdits)), LCount]);
      LNew := NormalizeLineEndings(AEdits[I].NewText, LStyle);
      Result := ReplaceN(Result, LOld, LNew, AEdits[I].MaxReplacements, LReplacements);
      Inc(AReplacements, LReplacements);
    end;
  finally
    LRanges.Free;
  end;
end;

// Common tail of both edit functions: computes the diff and writes (or, on a
// dry run, simulates writing) the modified content. The write goes through
// WriteTextFile so a dry run reports the same encoding, upgrades and
// warnings as a real edit.
procedure FinishEdit(const APath: string; ACacheManager: TCacheManager;
  const AReadResult: TReadResult; const AModified: string; ADryRun: Boolean;
  ATimestampAtRead: TDateTime; var AResult: TEditResult);
var
  LWriteOptions: TWriteOptions;
  LWriteResult: TWriteResult;
begin
  AResult.Changed := AModified <> AReadResult.Content;
  if not AResult.Changed then
  begin
    AResult.EncodingId := AReadResult.EncodingId;
    AResult.HasBom := AReadResult.HasBom;
    AResult.LineEnding := AReadResult.LineEnding;
    AResult.BytesWritten := AReadResult.BytesRead;
    Exit;
  end;
  AResult.Diff := GenerateDiff(AReadResult.Content, AModified);

  // Optimistic lock: the writer verifies, under its file lock, that the
  // file is unchanged since it was read and raises EFileModifiedError if not.
  LWriteOptions := MakeDefaultWriteOptions;
  LWriteOptions.DryRun := ADryRun;
  LWriteOptions.RequireUnchangedSince := ATimestampAtRead;
  LWriteResult := WriteTextFile(APath, AModified, ACacheManager, LWriteOptions);

  AResult.EncodingId := LWriteResult.EncodingId;
  AResult.HasBom := LWriteResult.HasBom;
  AResult.LineEnding := LWriteResult.LineEnding;
  AResult.BytesWritten := LWriteResult.BytesWritten;
  AResult.UpgradedFrom := LWriteResult.UpgradedFrom;
  AResult.Warnings := LWriteResult.Warnings;
end;

function ExecuteEdits(const APath: string; ACacheManager: TCacheManager;
  const AEdits: TArray<TEditOptions>; ADryRun: Boolean): TEditResult;
var
  LReadResult: TReadResult;
  LModified, LRelative: string;
  LReplacements: Integer;
  LTimestampAtRead: TDateTime;
  LCache: TEncodingCache;
begin
  Result := Default(TEditResult);
  if Length(AEdits) = 0 then
    raise EEditError.Create('Edits array must not be empty');

  // Read once with encoding detection and capture timestamp for optimistic lock
  LTimestampAtRead := TFile.GetLastWriteTime(APath);
  LReadResult := ReadTextFile(APath, ACacheManager);
  ACacheManager.Resolve(APath, LCache, LRelative);
  LModified := ApplyEdits(LReadResult.Content, AEdits,
    FallbackLineEnding(LCache, LRelative), LReplacements);

  Result.Replacements := LReplacements;
  FinishEdit(APath, ACacheManager, LReadResult, LModified, ADryRun,
    LTimestampAtRead, Result);
end;

function EditTextFile(const APath: string; ACacheManager: TCacheManager;
  const AOptions: TEditOptions): TEditResult;
begin
  Result := ExecuteEdits(APath, ACacheManager, [AOptions], AOptions.DryRun);
end;

function EditTextFileMulti(const APath: string; ACacheManager: TCacheManager;
  const AEdits: TArray<TEditOptions>; ADryRun: Boolean): TEditResult;
begin
  Result := ExecuteEdits(APath, ACacheManager, AEdits, ADryRun);
end;

end.
