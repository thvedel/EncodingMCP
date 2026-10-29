unit Tests.FileIO.EditRange;

/// <summary>
///   Tests for range deletion/appending, line-ending normalisation of
///   oldText/newText (including Mixed files), original-snapshot semantics of
///   multi-edit line ranges and the multi-hunk diff output.
/// </summary>

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  Encoding.CacheManager,
  FileIO.Editor;

type
  [TestFixture]
  TEditRangeTests = class
  strict private
    FTempDir: string;
    FCacheManager: TCacheManager;
    function WriteFile(const AName, AContent: string): string;
    function ReadFile(const APath: string): string;
    function NumberedLines(ACount: Integer): string;
    function RangeEdit(AStart, AEnd: Integer; const ANewText: string): TEditOptions;
    function ReplaceEdit(const AOldText, ANewText: string): TEditOptions;
    function CountText(const AText, APattern: string): Integer;
  public
    [Setup]
    procedure Setup;
    [Teardown]
    procedure Teardown;

    [Test]
    procedure RangeDelete_EmptyNewText_RemovesLinesAndTerminators;
    [Test]
    procedure RangeDelete_UnterminatedLastLine;
    [Test]
    procedure RangeReplace_NewTextWithTrailingBreak_AddsNoBlankLine;
    [Test]
    procedure RangeAppend_OnePastLastLine;
    [Test]
    procedure RangeAppend_AfterUnterminatedLastLine_TerminatesIt;
    [Test]
    procedure Range_StartBeyondEnd_Raises;
    [Test]
    procedure OldText_WithLf_MatchesCrlfFile;
    [Test]
    procedure MixedFile_RangeInsert_UsesDominantStyle;
    [Test]
    procedure MixedFile_SearchReplace_UsesDominantStyle;
    [Test]
    procedure Multi_RangesReferToOriginalFile;
    [Test]
    procedure Multi_OverlappingRanges_RaiseAndKeepFile;
    [Test]
    procedure Multi_SameAppendPosition_Raises;
    [Test]
    procedure Multi_RangeAndSearchReplace_BothApplied;
    [Test]
    procedure Multi_SearchReplaceAffectedByRange_RaisesAmbiguous;
    [Test]
    procedure Diff_CrlfFile_ShowsNoCarriageReturns;
    [Test]
    procedure Diff_MixedFile_MarksDeviatingLineBreak;
    [Test]
    procedure Diff_DistantEdits_ProduceSeparateHunks;
    [Test]
    procedure Diff_HunkHeader_HasCorrectNumbers;
    [Test]
    procedure Diff_UnterminatedLastLine_IsMarked;
    [Test]
    procedure SingleLineFile_MultiLineNewText_UsesCrlfFallback;
    [Test]
    procedure SingleLineFile_CachedLfStyle_UsesLf;
    [Test]
    procedure EmptyFile_RangeAppend_AndSearchReplaceRaises;
    [Test]
    procedure CrOnlyFile_RangeEdit_KeepsCrAndMarksDeviation;
    [Test]
    procedure Multi_RangeDeletesAndInsertsSameMatch_RaisesAmbiguous;
    [Test]
    procedure Multi_RangeWithMaxReplacements_AppliesToSearchReplace;
    [Test]
    procedure OldTextWithStartLine_RaisesMutuallyExclusive;
    [Test]
    procedure Multi_OldTextWithEndLine_RaisesWithEditPrefix;
    [Test]
    procedure Diff_LargeEditDistance_FallsBackToSingleHunk;
  end;

implementation

uses
  System.IOUtils,
  Encoding.Types,
  Encoding.Cache,
  Encoding.Workspace;

{ TEditRangeTests }

procedure TEditRangeTests.Setup;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'EditRangeTests_' +
    FormatDateTime('yyyymmddhhnnsszzz', Now));
  TDirectory.CreateDirectory(FTempDir);
  TDirectory.CreateDirectory(TPath.Combine(FTempDir, '.git'));
  SetWorkspaceRoots([FTempDir]);
  FCacheManager := TCacheManager.Create;
end;

procedure TEditRangeTests.Teardown;
begin
  FreeAndNil(FCacheManager);
  SetWorkspaceRoots([]);
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

function TEditRangeTests.WriteFile(const AName, AContent: string): string;
begin
  Result := TPath.Combine(FTempDir, AName);
  TFile.WriteAllBytes(Result, TEncoding.ASCII.GetBytes(AContent));
end;

function TEditRangeTests.ReadFile(const APath: string): string;
begin
  Result := TEncoding.ASCII.GetString(TFile.ReadAllBytes(APath));
end;

function TEditRangeTests.NumberedLines(ACount: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to ACount do
    Result := Result + 'L' + IntToStr(I) + #13#10;
end;

function TEditRangeTests.RangeEdit(AStart, AEnd: Integer;
  const ANewText: string): TEditOptions;
begin
  Result := MakeDefaultEditOptions;
  Result.StartLine := AStart;
  Result.EndLine := AEnd;
  Result.NewText := ANewText;
end;

function TEditRangeTests.ReplaceEdit(const AOldText, ANewText: string): TEditOptions;
begin
  Result := MakeDefaultEditOptions;
  Result.OldText := AOldText;
  Result.NewText := ANewText;
end;

function TEditRangeTests.CountText(const AText, APattern: string): Integer;
var
  LPos: Integer;
begin
  Result := 0;
  LPos := Pos(APattern, AText);
  while LPos > 0 do
  begin
    Inc(Result);
    LPos := Pos(APattern, AText, LPos + Length(APattern));
  end;
end;

procedure TEditRangeTests.RangeDelete_EmptyNewText_RemovesLinesAndTerminators;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', 'a'#13#10'b'#13#10'c'#13#10'd'#13#10);
  EditTextFile(LPath, FCacheManager, RangeEdit(2, 3, ''));
  Assert.AreEqual('a'#13#10'd'#13#10, ReadFile(LPath));
end;

procedure TEditRangeTests.RangeDelete_UnterminatedLastLine;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', 'a'#13#10'b');
  EditTextFile(LPath, FCacheManager, RangeEdit(2, 2, ''));
  Assert.AreEqual('a'#13#10, ReadFile(LPath));
end;

procedure TEditRangeTests.RangeReplace_NewTextWithTrailingBreak_AddsNoBlankLine;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', 'a'#13#10'b'#13#10'c'#13#10);
  EditTextFile(LPath, FCacheManager, RangeEdit(2, 2, 'x'#10));
  Assert.AreEqual('a'#13#10'x'#13#10'c'#13#10, ReadFile(LPath));
end;

procedure TEditRangeTests.RangeAppend_OnePastLastLine;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', 'a'#13#10'b'#13#10);
  EditTextFile(LPath, FCacheManager, RangeEdit(3, 3, 'c'#10));
  Assert.AreEqual('a'#13#10'b'#13#10'c'#13#10, ReadFile(LPath));
end;

procedure TEditRangeTests.RangeAppend_AfterUnterminatedLastLine_TerminatesIt;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', 'a'#13#10'b');
  EditTextFile(LPath, FCacheManager, RangeEdit(3, 3, 'c'));
  Assert.AreEqual('a'#13#10'b'#13#10'c', ReadFile(LPath));
end;

procedure TEditRangeTests.Range_StartBeyondEnd_Raises;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', 'a'#13#10);
  Assert.WillRaise(
    procedure
    begin
      EditTextFile(LPath, FCacheManager, RangeEdit(5, 5, 'x'));
    end, EEditError);
  Assert.AreEqual('a'#13#10, ReadFile(LPath));
end;

procedure TEditRangeTests.OldText_WithLf_MatchesCrlfFile;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', 'line1'#13#10'line2'#13#10'line3'#13#10);
  EditTextFile(LPath, FCacheManager, ReplaceEdit('line1'#10'line2', 'x'#10'y'));
  Assert.AreEqual('x'#13#10'y'#13#10'line3'#13#10, ReadFile(LPath));
end;

procedure TEditRangeTests.MixedFile_RangeInsert_UsesDominantStyle;
var
  LPath: string;
begin
  // Three CRLF and one LF: CRLF dominates, the deviating LF is preserved
  LPath := WriteFile('a.txt', 'a'#13#10'b'#13#10'c'#10'd'#13#10);
  EditTextFile(LPath, FCacheManager, RangeEdit(1, 1, 'x'#10'y'));
  Assert.AreEqual('x'#13#10'y'#13#10'b'#13#10'c'#10'd'#13#10, ReadFile(LPath));
end;

procedure TEditRangeTests.MixedFile_SearchReplace_UsesDominantStyle;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', 'a'#13#10'b'#13#10'c'#10'd'#13#10);
  EditTextFile(LPath, FCacheManager, ReplaceEdit('b', 'b1'#10'b2'));
  Assert.AreEqual('a'#13#10'b1'#13#10'b2'#13#10'c'#10'd'#13#10, ReadFile(LPath));
end;

procedure TEditRangeTests.Multi_RangesReferToOriginalFile;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', NumberedLines(10));
  // Edit 1 adds a line and edit 2 removes one; edits 2 and 3 still use the
  // original line numbers.
  EditTextFileMulti(LPath, FCacheManager,
    [RangeEdit(2, 2, 'X'#10'Y'), RangeEdit(5, 5, ''), RangeEdit(8, 9, 'Z')]);
  Assert.AreEqual(
    'L1'#13#10'X'#13#10'Y'#13#10'L3'#13#10'L4'#13#10'L6'#13#10'L7'#13#10 +
    'Z'#13#10'L10'#13#10, ReadFile(LPath));
end;

procedure TEditRangeTests.Multi_OverlappingRanges_RaiseAndKeepFile;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', NumberedLines(10));
  Assert.WillRaise(
    procedure
    begin
      EditTextFileMulti(LPath, FCacheManager, [RangeEdit(2, 4, 'A'), RangeEdit(4, 5, 'B')]);
    end, EEditError);
  Assert.AreEqual(NumberedLines(10), ReadFile(LPath));
end;

procedure TEditRangeTests.Multi_SameAppendPosition_Raises;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', NumberedLines(3));
  Assert.WillRaise(
    procedure
    begin
      EditTextFileMulti(LPath, FCacheManager, [RangeEdit(4, 4, 'A'), RangeEdit(4, 4, 'B')]);
    end, EEditError);
end;

procedure TEditRangeTests.Multi_RangeAndSearchReplace_BothApplied;
var
  LPath: string;
  LResult: TEditResult;
begin
  LPath := WriteFile('a.txt', NumberedLines(6));
  LResult := EditTextFileMulti(LPath, FCacheManager,
    [ReplaceEdit('L5', 'Q'), RangeEdit(1, 1, 'First')]);
  Assert.AreEqual(2, LResult.Replacements);
  Assert.AreEqual('First'#13#10'L2'#13#10'L3'#13#10'L4'#13#10'Q'#13#10'L6'#13#10,
    ReadFile(LPath));
end;

procedure TEditRangeTests.Multi_SearchReplaceAffectedByRange_RaisesAmbiguous;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', NumberedLines(6));
  Assert.WillRaise(
    procedure
    begin
      EditTextFileMulti(LPath, FCacheManager, [RangeEdit(2, 2, 'L5'), ReplaceEdit('L5', 'Q')]);
    end, EEditError);
  Assert.AreEqual(NumberedLines(6), ReadFile(LPath));
end;

procedure TEditRangeTests.Diff_CrlfFile_ShowsNoCarriageReturns;
var
  LPath: string;
  LResult: TEditResult;
begin
  LPath := WriteFile('a.txt', NumberedLines(5));
  LResult := EditTextFileMulti(LPath, FCacheManager, [RangeEdit(3, 3, 'X'#10'Y')], True);
  Assert.IsFalse(LResult.Diff.Contains(#13), 'Diff must not contain CR');
  Assert.IsTrue(LResult.Diff.Contains('-L3'#10));
  Assert.IsTrue(LResult.Diff.Contains('+X'#10'+Y'#10));
  Assert.IsFalse(LResult.Diff.Contains('['), 'No markers expected in a pure CRLF file');
  Assert.AreEqual(NumberedLines(5), ReadFile(LPath), 'Dry run must not write');
end;

procedure TEditRangeTests.Diff_MixedFile_MarksDeviatingLineBreak;
var
  LPath: string;
  LResult: TEditResult;
begin
  LPath := WriteFile('a.txt', 'a'#13#10'b'#10'c'#13#10'd'#13#10);
  LResult := EditTextFile(LPath, FCacheManager, RangeEdit(3, 3, 'x'));
  Assert.IsTrue(LResult.Diff.Contains(' b [LF]'#10), LResult.Diff);
  Assert.IsTrue(LResult.Diff.Contains('+x'#10), LResult.Diff);
  Assert.AreEqual('a'#13#10'b'#10'x'#13#10'd'#13#10, ReadFile(LPath));
end;

procedure TEditRangeTests.Diff_DistantEdits_ProduceSeparateHunks;
var
  LPath: string;
  LResult: TEditResult;
begin
  LPath := WriteFile('a.txt', NumberedLines(100));
  LResult := EditTextFileMulti(LPath, FCacheManager,
    [RangeEdit(10, 10, 'A'), RangeEdit(90, 90, 'B')], True);
  Assert.AreEqual(2, CountText(LResult.Diff, '@@ -'), LResult.Diff);
  Assert.IsFalse(LResult.Diff.Contains(' L50'#10), 'Unchanged middle must not be in the diff');
  Assert.IsTrue(LResult.Diff.Contains('@@ -7,7 +7,7 @@'), LResult.Diff);
  Assert.IsTrue(LResult.Diff.Contains('@@ -87,7 +87,7 @@'), LResult.Diff);
end;

procedure TEditRangeTests.Diff_HunkHeader_HasCorrectNumbers;
var
  LPath: string;
  LResult: TEditResult;
begin
  LPath := WriteFile('a.txt', NumberedLines(10));
  LResult := EditTextFile(LPath, FCacheManager, RangeEdit(5, 5, ''));
  Assert.AreEqual(
    '@@ -2,7 +2,6 @@'#10' L2'#10' L3'#10' L4'#10'-L5'#10' L6'#10' L7'#10' L8'#10,
    LResult.Diff);
end;

procedure TEditRangeTests.Diff_UnterminatedLastLine_IsMarked;
var
  LPath: string;
  LResult: TEditResult;
begin
  LPath := WriteFile('a.txt', 'a'#13#10'b');
  LResult := EditTextFile(LPath, FCacheManager, ReplaceEdit('b', 'c'));
  Assert.AreEqual(
    '@@ -1,2 +1,2 @@'#10' a'#10'-b'#10'\ No newline at end of file'#10 +
    '+c'#10'\ No newline at end of file'#10, LResult.Diff);
end;

procedure TEditRangeTests.SingleLineFile_MultiLineNewText_UsesCrlfFallback;
var
  LPath: string;
  LResult: TEditResult;
begin
  LPath := WriteFile('a.txt', 'only');
  LResult := EditTextFile(LPath, FCacheManager, RangeEdit(1, 1, 'x'#10'y'));
  // The replaced last line was unterminated, so the result stays unterminated;
  // the inserted line break must use the fallback style (CRLF).
  Assert.AreEqual('x'#13#10'y', ReadFile(LPath));
  Assert.AreEqual(TLineEnding.CrLf, LResult.LineEnding);
  Assert.IsFalse(LResult.Diff.Contains('['), 'Diff must agree with the written style: ' + LResult.Diff);
end;

procedure TEditRangeTests.SingleLineFile_CachedLfStyle_UsesLf;
var
  LPath, LRelative: string;
  LCache: TEncodingCache;
  LEntry: TCacheEntry;
  LResult: TEditResult;
begin
  LPath := WriteFile('a.txt', 'only');
  FCacheManager.Resolve(LPath, LCache, LRelative);
  LEntry := Default(TCacheEntry);
  LEntry.EncodingId := TEncodingId.Ascii;
  LEntry.LineEnding := TLineEnding.Lf;
  LCache.Put(LRelative, LEntry);
  LResult := EditTextFile(LPath, FCacheManager, RangeEdit(1, 1, 'x'#13#10'y'));
  Assert.AreEqual('x'#10'y', ReadFile(LPath));
  Assert.AreEqual(TLineEnding.Lf, LResult.LineEnding);
  Assert.IsFalse(LResult.Diff.Contains('['), LResult.Diff);
end;

procedure TEditRangeTests.EmptyFile_RangeAppend_AndSearchReplaceRaises;
var
  LPath: string;
begin
  LPath := WriteFile('a.txt', '');
  Assert.WillRaise(
    procedure
    begin
      EditTextFile(LPath, FCacheManager, ReplaceEdit('a', 'b'));
    end, EEditError);
  EditTextFile(LPath, FCacheManager, RangeEdit(1, 0, 'first'));
  // An empty file carries no encoding information and is written like a new
  // file: UTF-8 with BOM. Nothing precedes the new line, so it is unterminated.
  Assert.AreEqual(TEncoding.UTF8.GetPreamble + TEncoding.UTF8.GetBytes('first'),
    TFile.ReadAllBytes(LPath));
end;

procedure TEditRangeTests.CrOnlyFile_RangeEdit_KeepsCrAndMarksDeviation;
var
  LPath: string;
  LResult: TEditResult;
begin
  LPath := WriteFile('a.txt', 'a'#13'b'#13#10'c'#13'd'#13);
  LResult := EditTextFile(LPath, FCacheManager, RangeEdit(3, 3, 'x'#10'y'));
  Assert.AreEqual('a'#13'b'#13#10'x'#13'y'#13'd'#13, ReadFile(LPath));
  Assert.IsTrue(LResult.Diff.Contains(' b [CRLF]'#10), LResult.Diff);
  Assert.IsFalse(LResult.Diff.Contains('[CR]'), LResult.Diff);
end;

procedure TEditRangeTests.Multi_RangeDeletesAndInsertsSameMatch_RaisesAmbiguous;
var
  LPath: string;
begin
  // The occurrence count of 'L2' is unchanged (one deleted, one inserted),
  // so only the content check can detect that the range touches the match.
  LPath := WriteFile('a.txt', NumberedLines(6));
  Assert.WillRaise(
    procedure
    begin
      EditTextFileMulti(LPath, FCacheManager, [RangeEdit(2, 2, 'xL2x'), ReplaceEdit('L2', 'Q')]);
    end, EEditError);
  Assert.AreEqual(NumberedLines(6), ReadFile(LPath));
end;

procedure TEditRangeTests.OldTextWithStartLine_RaisesMutuallyExclusive;
var
  LPath: string;
  LOptions: TEditOptions;
  LMessage: string;
begin
  // Before the check, startLine was silently ignored and the search/replace ran.
  LPath := WriteFile('a.txt', NumberedLines(3));
  LOptions := ReplaceEdit('L2', 'Q');
  LOptions.StartLine := 2;
  LMessage := '';
  try
    EditTextFile(LPath, FCacheManager, LOptions);
  except
    on E: EEditError do
      LMessage := E.Message;
  end;
  Assert.IsTrue(LMessage.StartsWith('oldText and startLine/endLine are mutually exclusive'), LMessage);
  Assert.AreEqual(NumberedLines(3), ReadFile(LPath));
end;

procedure TEditRangeTests.Multi_OldTextWithEndLine_RaisesWithEditPrefix;
var
  LPath: string;
  LBad: TEditOptions;
  LMessage: string;
begin
  LPath := WriteFile('a.txt', NumberedLines(3));
  LBad := ReplaceEdit('L3', 'Q');
  LBad.EndLine := 3;
  LMessage := '';
  try
    EditTextFileMulti(LPath, FCacheManager, [ReplaceEdit('L1', 'X'), LBad]);
  except
    on E: EEditError do
      LMessage := E.Message;
  end;
  Assert.IsTrue(LMessage.StartsWith('Edit 2: oldText and startLine/endLine'), LMessage);
  Assert.AreEqual(NumberedLines(3), ReadFile(LPath));
end;

procedure TEditRangeTests.Multi_RangeWithMaxReplacements_AppliesToSearchReplace;
var
  LPath: string;
  LEdit: TEditOptions;
  LResult: TEditResult;
begin
  LPath := WriteFile('a.txt', 'k=1'#13#10'k=2'#13#10'k=3'#13#10'end'#13#10);
  LEdit := ReplaceEdit('k=', 'v=');
  LEdit.MaxReplacements := 0;
  LResult := EditTextFileMulti(LPath, FCacheManager, [RangeEdit(4, 4, 'stop'), LEdit]);
  Assert.AreEqual('v=1'#13#10'v=2'#13#10'v=3'#13#10'stop'#13#10, ReadFile(LPath));
  Assert.AreEqual(4, LResult.Replacements, 'range edit counts as 1, unlimited replace as 3');
  LEdit.MaxReplacements := 2;
  LEdit.OldText := 'v=';
  LEdit.NewText := 'w=';
  LResult := EditTextFileMulti(LPath, FCacheManager, [LEdit]);
  Assert.AreEqual('w=1'#13#10'w=2'#13#10'v=3'#13#10'stop'#13#10, ReadFile(LPath),
    'maxReplacements 2 replaces the first two matches only');
  Assert.AreEqual(2, LResult.Replacements);
end;

procedure TEditRangeTests.Diff_LargeEditDistance_FallsBackToSingleHunk;
var
  LPath, LNew: string;
  LResult: TEditResult;
  I: Integer;
begin
  // Replacing 3000 lines with 3000 different lines exceeds the Myers limit
  // (2000); the diff must still be produced, as one replace block.
  LPath := WriteFile('a.txt', NumberedLines(3000));
  LNew := '';
  for I := 1 to 3000 do
    LNew := LNew + 'N' + I.ToString + #13#10;
  LResult := EditTextFile(LPath, FCacheManager, RangeEdit(1, 3000, LNew));
  Assert.IsTrue(LResult.Changed);
  Assert.AreEqual(LNew, ReadFile(LPath));
  Assert.AreEqual(1, CountText(LResult.Diff, '@@ -'), LResult.Diff.Substring(0, 200));
  Assert.AreEqual(3000, CountText(LResult.Diff, #10'-L'));
  Assert.AreEqual(3000, CountText(LResult.Diff, #10'+N'));
end;

initialization
  TDUnitX.RegisterTestFixture(TEditRangeTests);

end.
