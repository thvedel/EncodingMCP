unit Tests.FileIO.EditFile;

/// <summary>
///   Tests for the edit_text_file functionality (search/replace and
///   line-range replacement) in FileIO.Editor.
/// </summary>

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  Encoding.CacheManager;

type
  [TestFixture]
  TEditFileTests = class
  strict private
    FTempDir: string;
    FCacheManager: TCacheManager;
    function MakeTempPath(const AFileName: string): string;
    procedure WriteUtf8File(const APath, AContent: string);
    function ReadFileContent(const APath: string): string;
  public
    [Setup]
    procedure Setup;
    [Teardown]
    procedure Teardown;

    // Search/replace mode
    [Test]
    procedure SearchReplace_SingleMatch;
    [Test]
    procedure SearchReplace_NoMatch_RaisesError;
    [Test]
    procedure SearchReplace_MultipleMatches_DefaultMax1_RaisesError;
    [Test]
    procedure SearchReplace_MultipleMatches_MaxUnlimited;
    [Test]
    procedure SearchReplace_MultipleMatches_Max2;
    [Test]
    procedure SearchReplace_EmptyNewText_DeletesMatch;
    [Test]
    procedure SearchReplace_PreservesEncoding;

    // Range replacement mode
    [Test]
    procedure RangeReplace_MiddleLines;
    [Test]
    procedure RangeReplace_FirstLine;
    [Test]
    procedure RangeReplace_LastLine;
    [Test]
    procedure RangeReplace_EntireFile;
    [Test]
    procedure RangeReplace_ClampsBeyondEnd;
    [Test]
    procedure RangeReplace_InvalidRange_RaisesError;

    // Edge cases
    [Test]
    procedure Edit_NoChange_DoesNotRewrite;
    [Test]
    procedure Edit_MissingOldTextAndRange_RaisesError;

    // Diff output
    [Test]
    procedure Diff_ContainsChangedLines;
    [Test]
    procedure Diff_EmptyWhenNoChange;
    [Test]
    procedure Diff_MultiEdit_ShowsAllChanges;

    // Multi-edit (atomic)
    [Test]
    procedure MultiEdit_TwoEditsApplied;
    [Test]
    procedure MultiEdit_SecondEditFails_NothingWritten;
    [Test]
    procedure MultiEdit_DryRun_NoWrite;
    [Test]
    procedure MultiEdit_EmptyArray_Raises;
    [Test]
    procedure MultiEdit_MixedModes;
  end;

implementation

uses
  System.IOUtils,
  System.Classes,
  Encoding.Types,
  FileIO.Reader,
  FileIO.Editor;

{ TEditFileTests }

function TEditFileTests.MakeTempPath(const AFileName: string): string;
begin
  Result := TPath.Combine(FTempDir, AFileName);
end;

procedure TEditFileTests.WriteUtf8File(const APath, AContent: string);
var
  LStream: TStreamWriter;
begin
  LStream := TStreamWriter.Create(APath, False, TEncoding.UTF8);
  try
    LStream.Write(AContent);
  finally
    LStream.Free;
  end;
end;

function TEditFileTests.ReadFileContent(const APath: string): string;
var
  LResult: TReadResult;
begin
  LResult := ReadTextFile(APath, FCacheManager);
  Result := LResult.Content;
end;

procedure TEditFileTests.Setup;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'EncodingMCPTests_Edit_' +
    FormatDateTime('yyyymmddhhnnsszzz', Now));
  TDirectory.CreateDirectory(FTempDir);
  TDirectory.CreateDirectory(TPath.Combine(FTempDir, '.git'));
  FCacheManager := TCacheManager.Create;
end;

procedure TEditFileTests.Teardown;
begin
  FreeAndNil(FCacheManager);
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

procedure TEditFileTests.SearchReplace_SingleMatch;
var
  LPath: string;
  LOptions: TEditOptions;
  LResult: TEditResult;
begin
  LPath := MakeTempPath('single.txt');
  WriteUtf8File(LPath, 'Hello World');
  LOptions := MakeDefaultEditOptions;
  LOptions.OldText := 'World';
  LOptions.NewText := 'Delphi';
  LResult := EditTextFile(LPath, FCacheManager, LOptions);
  Assert.IsTrue(LResult.Changed);
  Assert.AreEqual(1, LResult.Replacements);
  Assert.AreEqual('Hello Delphi', ReadFileContent(LPath));
end;

procedure TEditFileTests.SearchReplace_NoMatch_RaisesError;
var
  LPath: string;
  LOptions: TEditOptions;
begin
  LPath := MakeTempPath('nomatch.txt');
  WriteUtf8File(LPath, 'Hello World');
  LOptions := MakeDefaultEditOptions;
  LOptions.OldText := 'NotFound';
  LOptions.NewText := 'X';
  Assert.WillRaise(
    procedure begin EditTextFile(LPath, FCacheManager, LOptions); end,
    EEditError);
end;

procedure TEditFileTests.SearchReplace_MultipleMatches_DefaultMax1_RaisesError;
var
  LPath: string;
  LOptions: TEditOptions;
begin
  LPath := MakeTempPath('multi_err.txt');
  WriteUtf8File(LPath, 'foo bar foo baz foo');
  LOptions := MakeDefaultEditOptions;
  LOptions.OldText := 'foo';
  LOptions.NewText := 'qux';
  // Default MaxReplacements = 1, but 3 matches exist
  Assert.WillRaise(
    procedure begin EditTextFile(LPath, FCacheManager, LOptions); end,
    EEditError);
end;

procedure TEditFileTests.SearchReplace_MultipleMatches_MaxUnlimited;
var
  LPath: string;
  LOptions: TEditOptions;
  LResult: TEditResult;
begin
  LPath := MakeTempPath('multi_all.txt');
  WriteUtf8File(LPath, 'foo bar foo baz foo');
  LOptions := MakeDefaultEditOptions;
  LOptions.OldText := 'foo';
  LOptions.NewText := 'qux';
  LOptions.MaxReplacements := 0; // unlimited
  LResult := EditTextFile(LPath, FCacheManager, LOptions);
  Assert.AreEqual(3, LResult.Replacements);
  Assert.AreEqual('qux bar qux baz qux', ReadFileContent(LPath));
end;

procedure TEditFileTests.SearchReplace_MultipleMatches_Max2;
var
  LPath: string;
  LOptions: TEditOptions;
  LResult: TEditResult;
begin
  LPath := MakeTempPath('multi_2.txt');
  WriteUtf8File(LPath, 'foo bar foo baz foo');
  LOptions := MakeDefaultEditOptions;
  LOptions.OldText := 'foo';
  LOptions.NewText := 'qux';
  LOptions.MaxReplacements := 2;
  LResult := EditTextFile(LPath, FCacheManager, LOptions);
  Assert.AreEqual(2, LResult.Replacements);
  Assert.AreEqual('qux bar qux baz foo', ReadFileContent(LPath));
end;

procedure TEditFileTests.SearchReplace_EmptyNewText_DeletesMatch;
var
  LPath: string;
  LOptions: TEditOptions;
  LResult: TEditResult;
begin
  LPath := MakeTempPath('delete.txt');
  WriteUtf8File(LPath, 'Hello World');
  LOptions := MakeDefaultEditOptions;
  LOptions.OldText := ' World';
  LOptions.NewText := '';
  LResult := EditTextFile(LPath, FCacheManager, LOptions);
  Assert.AreEqual('Hello', ReadFileContent(LPath));
end;

procedure TEditFileTests.SearchReplace_PreservesEncoding;
var
  LPath: string;
  LOptions: TEditOptions;
  LResult: TEditResult;
  LBytes: TBytes;
begin
  LPath := MakeTempPath('enc.pas');
  // Write Windows-1252 file: 'Hej æøå verden' (E6=æ, F8=ø, E5=å)
  LBytes := TBytes.Create($48, $65, $6A, $20, $E6, $F8, $E5, $20,
    $76, $65, $72, $64, $65, $6E);
  TFile.WriteAllBytes(LPath, LBytes);
  // Read to cache encoding
  ReadTextFile(LPath, FCacheManager);
  // Edit: replace 'verden' with 'jord'
  LOptions := MakeDefaultEditOptions;
  LOptions.OldText := 'verden';
  LOptions.NewText := 'jord';
  LResult := EditTextFile(LPath, FCacheManager, LOptions);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId);
  Assert.IsTrue(LResult.Changed);
end;

procedure TEditFileTests.RangeReplace_MiddleLines;
var
  LPath: string;
  LOptions: TEditOptions;
  LResult: TEditResult;
begin
  LPath := MakeTempPath('range_mid.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C' + #10 + 'D' + #10 + 'E');
  LOptions := MakeDefaultEditOptions;
  LOptions.StartLine := 2;
  LOptions.EndLine := 4;
  LOptions.NewText := 'X' + #10 + 'Y';
  LResult := EditTextFile(LPath, FCacheManager, LOptions);
  Assert.IsTrue(LResult.Changed);
  Assert.AreEqual('A' + #10 + 'X' + #10 + 'Y' + #10 + 'E', ReadFileContent(LPath));
end;

procedure TEditFileTests.RangeReplace_FirstLine;
var
  LPath: string;
begin
  LPath := MakeTempPath('range_first.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C');
  var LOpts := MakeDefaultEditOptions;
  LOpts.StartLine := 1;
  LOpts.EndLine := 1;
  LOpts.NewText := 'Z';
  EditTextFile(LPath, FCacheManager, LOpts);
  Assert.AreEqual('Z' + #10 + 'B' + #10 + 'C', ReadFileContent(LPath));
end;

procedure TEditFileTests.RangeReplace_LastLine;
var
  LPath: string;
begin
  LPath := MakeTempPath('range_last.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C');
  var LOpts := MakeDefaultEditOptions;
  LOpts.StartLine := 3;
  LOpts.EndLine := 3;
  LOpts.NewText := 'Z';
  EditTextFile(LPath, FCacheManager, LOpts);
  Assert.AreEqual('A' + #10 + 'B' + #10 + 'Z', ReadFileContent(LPath));
end;

procedure TEditFileTests.RangeReplace_EntireFile;
var
  LPath: string;
begin
  LPath := MakeTempPath('range_all.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C');
  var LOpts := MakeDefaultEditOptions;
  LOpts.StartLine := 1;
  LOpts.EndLine := 3;
  LOpts.NewText := 'NEW';
  EditTextFile(LPath, FCacheManager, LOpts);
  Assert.AreEqual('NEW', ReadFileContent(LPath));
end;

procedure TEditFileTests.RangeReplace_ClampsBeyondEnd;
var
  LPath: string;
begin
  LPath := MakeTempPath('range_clamp.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C');
  var LOpts := MakeDefaultEditOptions;
  LOpts.StartLine := 2;
  LOpts.EndLine := 100;
  LOpts.NewText := 'Z';
  EditTextFile(LPath, FCacheManager, LOpts);
  Assert.AreEqual('A' + #10 + 'Z', ReadFileContent(LPath));
end;

procedure TEditFileTests.RangeReplace_InvalidRange_RaisesError;
var
  LPath: string;
  LOptions: TEditOptions;
begin
  LPath := MakeTempPath('range_inv.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C');
  LOptions := MakeDefaultEditOptions;
  LOptions.StartLine := 3;
  LOptions.EndLine := 1;
  LOptions.NewText := 'X';
  Assert.WillRaise(
    procedure begin EditTextFile(LPath, FCacheManager, LOptions); end,
    EEditError);
end;

procedure TEditFileTests.Edit_NoChange_DoesNotRewrite;
var
  LPath: string;
  LOptions: TEditOptions;
  LResult: TEditResult;
begin
  LPath := MakeTempPath('nochange.txt');
  WriteUtf8File(LPath, 'Hello');
  LOptions := MakeDefaultEditOptions;
  LOptions.OldText := 'Hello';
  LOptions.NewText := 'Hello'; // same text
  LResult := EditTextFile(LPath, FCacheManager, LOptions);
  Assert.IsFalse(LResult.Changed);
end;

procedure TEditFileTests.Edit_MissingOldTextAndRange_RaisesError;
var
  LPath: string;
  LOptions: TEditOptions;
begin
  LPath := MakeTempPath('missing.txt');
  WriteUtf8File(LPath, 'Hello');
  LOptions := MakeDefaultEditOptions;
  LOptions.OldText := '';
  LOptions.NewText := 'X';
  // No startLine/endLine either
  Assert.WillRaise(
    procedure begin EditTextFile(LPath, FCacheManager, LOptions); end,
    EEditError);
end;

// --- Diff output ---

procedure TEditFileTests.Diff_ContainsChangedLines;
var
  LPath: string;
  LOptions: TEditOptions;
  LResult: TEditResult;
begin
  LPath := MakeTempPath('diff_basic.txt');
  WriteUtf8File(LPath, 'line1' + #10 + 'old' + #10 + 'line3');
  LOptions := MakeDefaultEditOptions;
  LOptions.OldText := 'old';
  LOptions.NewText := 'new';
  LResult := EditTextFile(LPath, FCacheManager, LOptions);
  Assert.IsTrue(LResult.Changed);
  Assert.IsTrue(LResult.Diff <> '', 'Diff should not be empty');
  Assert.IsTrue(LResult.Diff.Contains('-old'), 'Diff should contain removed line');
  Assert.IsTrue(LResult.Diff.Contains('+new'), 'Diff should contain added line');
  Assert.IsTrue(LResult.Diff.Contains('@@'), 'Diff should have hunk header');
end;

procedure TEditFileTests.Diff_EmptyWhenNoChange;
var
  LPath: string;
  LOptions: TEditOptions;
  LResult: TEditResult;
begin
  LPath := MakeTempPath('diff_nochange.txt');
  WriteUtf8File(LPath, 'same');
  LOptions := MakeDefaultEditOptions;
  LOptions.OldText := 'same';
  LOptions.NewText := 'same';
  LResult := EditTextFile(LPath, FCacheManager, LOptions);
  Assert.IsFalse(LResult.Changed);
  Assert.AreEqual('', LResult.Diff);
end;

procedure TEditFileTests.Diff_MultiEdit_ShowsAllChanges;
var
  LPath: string;
  LEdits: TArray<TEditOptions>;
  LResult: TEditResult;
begin
  LPath := MakeTempPath('diff_multi.txt');
  WriteUtf8File(LPath, 'alpha' + #10 + 'beta' + #10 + 'gamma');
  SetLength(LEdits, 2);
  LEdits[0] := MakeDefaultEditOptions;
  LEdits[0].OldText := 'alpha';
  LEdits[0].NewText := 'AAA';
  LEdits[1] := MakeDefaultEditOptions;
  LEdits[1].OldText := 'gamma';
  LEdits[1].NewText := 'GGG';
  LResult := EditTextFileMulti(LPath, FCacheManager, LEdits);
  Assert.IsTrue(LResult.Diff <> '', 'Multi-edit should produce diff');
  Assert.IsTrue(LResult.Diff.Contains('-alpha'), 'Should show removed alpha');
  Assert.IsTrue(LResult.Diff.Contains('+AAA'), 'Should show added AAA');
end;

// --- Multi-edit ---

procedure TEditFileTests.MultiEdit_TwoEditsApplied;
var
  LPath: string;
  LEdits: TArray<TEditOptions>;
  LResult: TEditResult;
begin
  LPath := MakeTempPath('multi_ok.txt');
  WriteUtf8File(LPath, 'alpha beta gamma');
  SetLength(LEdits, 2);
  LEdits[0] := MakeDefaultEditOptions;
  LEdits[0].OldText := 'alpha';
  LEdits[0].NewText := 'AAA';
  LEdits[1] := MakeDefaultEditOptions;
  LEdits[1].OldText := 'gamma';
  LEdits[1].NewText := 'GGG';
  LResult := EditTextFileMulti(LPath, FCacheManager, LEdits);
  Assert.IsTrue(LResult.Changed);
  Assert.AreEqual(2, LResult.Replacements);
  Assert.AreEqual('AAA beta GGG', ReadFileContent(LPath));
end;

procedure TEditFileTests.MultiEdit_SecondEditFails_NothingWritten;
var
  LPath: string;
  LEdits: TArray<TEditOptions>;
  LRaised: Boolean;
begin
  LPath := MakeTempPath('multi_fail.txt');
  WriteUtf8File(LPath, 'hello world');
  SetLength(LEdits, 2);
  LEdits[0] := MakeDefaultEditOptions;
  LEdits[0].OldText := 'hello';
  LEdits[0].NewText := 'hi';
  LEdits[1] := MakeDefaultEditOptions;
  LEdits[1].OldText := 'notfound';
  LEdits[1].NewText := 'x';
  LRaised := False;
  try
    EditTextFileMulti(LPath, FCacheManager, LEdits);
  except
    on E: EEditError do
      LRaised := True;
  end;
  Assert.IsTrue(LRaised, 'Should raise on second failed edit');
  // File unchanged - atomic rollback
  Assert.AreEqual('hello world', ReadFileContent(LPath));
end;

procedure TEditFileTests.MultiEdit_DryRun_NoWrite;
var
  LPath: string;
  LEdits: TArray<TEditOptions>;
  LResult: TEditResult;
begin
  LPath := MakeTempPath('multi_dry.txt');
  WriteUtf8File(LPath, 'foo bar');
  SetLength(LEdits, 1);
  LEdits[0] := MakeDefaultEditOptions;
  LEdits[0].OldText := 'foo';
  LEdits[0].NewText := 'baz';
  LResult := EditTextFileMulti(LPath, FCacheManager, LEdits, True);
  Assert.IsTrue(LResult.Changed);
  Assert.AreEqual(1, LResult.Replacements);
  // File not modified
  Assert.AreEqual('foo bar', ReadFileContent(LPath));
end;

procedure TEditFileTests.MultiEdit_EmptyArray_Raises;
var
  LPath: string;
  LEdits: TArray<TEditOptions>;
begin
  LPath := MakeTempPath('multi_empty.txt');
  WriteUtf8File(LPath, 'test');
  SetLength(LEdits, 0);
  Assert.WillRaise(
    procedure begin EditTextFileMulti(LPath, FCacheManager, LEdits); end,
    EEditError);
end;

procedure TEditFileTests.MultiEdit_MixedModes;
var
  LPath: string;
  LEdits: TArray<TEditOptions>;
  LResult: TEditResult;
begin
  // Mix search/replace and range-replace in one batch
  LPath := MakeTempPath('multi_mix.txt');
  WriteUtf8File(LPath, 'line1' + #10 + 'line2' + #10 + 'line3');
  SetLength(LEdits, 2);
  // Edit 1: replace line2 range with new text
  LEdits[0] := MakeDefaultEditOptions;
  LEdits[0].StartLine := 2;
  LEdits[0].EndLine := 2;
  LEdits[0].NewText := 'replaced';
  // Edit 2: search/replace on result
  LEdits[1] := MakeDefaultEditOptions;
  LEdits[1].OldText := 'line1';
  LEdits[1].NewText := 'first';
  LResult := EditTextFileMulti(LPath, FCacheManager, LEdits);
  Assert.IsTrue(LResult.Changed);
  Assert.AreEqual(2, LResult.Replacements);
  Assert.AreEqual('first' + #10 + 'replaced' + #10 + 'line3', ReadFileContent(LPath));
end;

initialization
  TDUnitX.RegisterTestFixture(TEditFileTests);

end.
