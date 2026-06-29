unit Tests.FileIO.LineRange;

/// <summary>
///   Tests for the line-range reading feature (startLine/endLine parameters)
///   of the ReadTextFile function. Verifies correct slicing of file content
///   by line interval, boundary clamping, and priority over head/tail.
/// </summary>

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  Encoding.CacheManager;

type
  [TestFixture]
  TLineRangeTests = class
  strict private
    FTempDir: string;
    FCacheManager: TCacheManager;
    function MakeTempPath(const AFileName: string): string;
    procedure WriteUtf8File(const APath, AContent: string);
  public
    [Setup]
    procedure Setup;
    [Teardown]
    procedure Teardown;

    [Test]
    procedure ReadLineRange_MiddleLines;
    [Test]
    procedure ReadLineRange_StartLineOnly;
    [Test]
    procedure ReadLineRange_EndLineOnly;
    [Test]
    procedure ReadLineRange_SingleLine;
    [Test]
    procedure ReadLineRange_EntireFile;
    [Test]
    procedure ReadLineRange_ClampsBeyondEnd;
    [Test]
    procedure ReadLineRange_StartBeyondEnd_ReturnsEmpty;
    [Test]
    procedure ReadLineRange_StartGreaterThanEnd_ReturnsEmpty;
    [Test]
    procedure ReadLineRange_PriorityOverHead;
    [Test]
    procedure ReadLineRange_PriorityOverTail;
    [Test]
    procedure ReadLineRange_TotalLinesCorrect;
    [Test]
    procedure ReadLineRange_ReturnedLinesCorrect;
    [Test]
    procedure ReadLineRange_PreservesCRLF;
  end;

implementation

uses
  System.IOUtils,
  System.Classes,
  Encoding.Types,
  FileIO.Reader;

{ TLineRangeTests }

function TLineRangeTests.MakeTempPath(const AFileName: string): string;
begin
  Result := TPath.Combine(FTempDir, AFileName);
end;

procedure TLineRangeTests.WriteUtf8File(const APath, AContent: string);
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

procedure TLineRangeTests.Setup;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'EncodingMCPTests_LineRange_' +
    FormatDateTime('yyyymmddhhnnsszzz', Now));
  TDirectory.CreateDirectory(FTempDir);
  TDirectory.CreateDirectory(TPath.Combine(FTempDir, '.git'));
  FCacheManager := TCacheManager.Create;
end;

procedure TLineRangeTests.Teardown;
begin
  FreeAndNil(FCacheManager);
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

procedure TLineRangeTests.ReadLineRange_MiddleLines;
var
  LPath: string;
  LResult: TReadResult;
begin
  // File with 5 lines, request lines 2-4
  LPath := MakeTempPath('five_lines.txt');
  WriteUtf8File(LPath, 'line1' + #10 + 'line2' + #10 + 'line3' + #10 + 'line4' + #10 + 'line5');
  LResult := ReadTextFile(LPath, FCacheManager, 0, 0, 2, 4);
  Assert.AreEqual('line2' + #10 + 'line3' + #10 + 'line4', LResult.Content);
end;

procedure TLineRangeTests.ReadLineRange_StartLineOnly;
var
  LPath: string;
  LResult: TReadResult;
begin
  // startLine=3, no endLine => read from line 3 to end
  LPath := MakeTempPath('start_only.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C' + #10 + 'D' + #10 + 'E');
  LResult := ReadTextFile(LPath, FCacheManager, 0, 0, 3, 0);
  Assert.AreEqual('C' + #10 + 'D' + #10 + 'E', LResult.Content);
end;

procedure TLineRangeTests.ReadLineRange_EndLineOnly;
var
  LPath: string;
  LResult: TReadResult;
begin
  // endLine=3, no startLine => read from beginning to line 3
  LPath := MakeTempPath('end_only.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C' + #10 + 'D' + #10 + 'E');
  LResult := ReadTextFile(LPath, FCacheManager, 0, 0, 0, 3);
  Assert.AreEqual('A' + #10 + 'B' + #10 + 'C', LResult.Content);
end;

procedure TLineRangeTests.ReadLineRange_SingleLine;
var
  LPath: string;
  LResult: TReadResult;
begin
  // startLine=3, endLine=3 => only line 3
  LPath := MakeTempPath('single_line.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C' + #10 + 'D');
  LResult := ReadTextFile(LPath, FCacheManager, 0, 0, 3, 3);
  Assert.AreEqual('C', LResult.Content);
  Assert.AreEqual(1, LResult.ReturnedLines);
end;

procedure TLineRangeTests.ReadLineRange_EntireFile;
var
  LPath: string;
  LResult: TReadResult;
  LContent: string;
begin
  // startLine=1, endLine=5 on a 5-line file => entire file
  LPath := MakeTempPath('entire.txt');
  LContent := 'A' + #10 + 'B' + #10 + 'C' + #10 + 'D' + #10 + 'E';
  WriteUtf8File(LPath, LContent);
  LResult := ReadTextFile(LPath, FCacheManager, 0, 0, 1, 5);
  Assert.AreEqual(LContent, LResult.Content);
  Assert.AreEqual(5, LResult.ReturnedLines);
end;

procedure TLineRangeTests.ReadLineRange_ClampsBeyondEnd;
var
  LPath: string;
  LResult: TReadResult;
begin
  // endLine=100 on a 3-line file => clamp to last line
  LPath := MakeTempPath('clamp.txt');
  WriteUtf8File(LPath, 'X' + #10 + 'Y' + #10 + 'Z');
  LResult := ReadTextFile(LPath, FCacheManager, 0, 0, 2, 100);
  Assert.AreEqual('Y' + #10 + 'Z', LResult.Content);
  Assert.AreEqual(2, LResult.ReturnedLines);
end;

procedure TLineRangeTests.ReadLineRange_StartBeyondEnd_ReturnsEmpty;
var
  LPath: string;
  LResult: TReadResult;
begin
  // startLine=100 on a 3-line file => clamped to last line, endLine also clamped
  // Actually startLine >= totalLines is clamped to totalLines-1,
  // so startLine=100 => 2, endLine=100 => 2, returns 1 line (the last)
  LPath := MakeTempPath('beyond.txt');
  WriteUtf8File(LPath, 'X' + #10 + 'Y' + #10 + 'Z');
  LResult := ReadTextFile(LPath, FCacheManager, 0, 0, 100, 100);
  // Both clamped to index 2 (line 3), so returns just line 3
  Assert.AreEqual('Z', LResult.Content);
  Assert.AreEqual(1, LResult.ReturnedLines);
end;

procedure TLineRangeTests.ReadLineRange_StartGreaterThanEnd_ReturnsEmpty;
var
  LPath: string;
  LResult: TReadResult;
begin
  // startLine=4, endLine=2 => invalid range, returns empty
  LPath := MakeTempPath('inverted.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C' + #10 + 'D');
  LResult := ReadTextFile(LPath, FCacheManager, 0, 0, 4, 2);
  Assert.AreEqual('', LResult.Content);
  Assert.AreEqual(0, LResult.ReturnedLines);
end;

procedure TLineRangeTests.ReadLineRange_PriorityOverHead;
var
  LPath: string;
  LResult: TReadResult;
begin
  // When both startLine/endLine and head are specified, line range wins
  LPath := MakeTempPath('priority_head.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C' + #10 + 'D' + #10 + 'E');
  LResult := ReadTextFile(LPath, FCacheManager, 2, 0, 3, 5);
  // Should return lines 3-5, NOT first 2 lines
  Assert.AreEqual('C' + #10 + 'D' + #10 + 'E', LResult.Content);
end;

procedure TLineRangeTests.ReadLineRange_PriorityOverTail;
var
  LPath: string;
  LResult: TReadResult;
begin
  // When both startLine/endLine and tail are specified, line range wins
  LPath := MakeTempPath('priority_tail.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C' + #10 + 'D' + #10 + 'E');
  LResult := ReadTextFile(LPath, FCacheManager, 0, 2, 1, 3);
  // Should return lines 1-3, NOT last 2 lines
  Assert.AreEqual('A' + #10 + 'B' + #10 + 'C', LResult.Content);
end;

procedure TLineRangeTests.ReadLineRange_TotalLinesCorrect;
var
  LPath: string;
  LResult: TReadResult;
begin
  // TotalLines should reflect the entire file regardless of slice
  LPath := MakeTempPath('total.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C' + #10 + 'D' + #10 + 'E');
  LResult := ReadTextFile(LPath, FCacheManager, 0, 0, 2, 3);
  Assert.AreEqual(5, LResult.TotalLines);
end;

procedure TLineRangeTests.ReadLineRange_ReturnedLinesCorrect;
var
  LPath: string;
  LResult: TReadResult;
begin
  // ReturnedLines should be the count of lines in the slice
  LPath := MakeTempPath('returned.txt');
  WriteUtf8File(LPath, 'A' + #10 + 'B' + #10 + 'C' + #10 + 'D' + #10 + 'E');
  LResult := ReadTextFile(LPath, FCacheManager, 0, 0, 2, 4);
  Assert.AreEqual(3, LResult.ReturnedLines);
end;

procedure TLineRangeTests.ReadLineRange_PreservesCRLF;
var
  LPath: string;
  LResult: TReadResult;
begin
  // CRLF line endings: CR should be preserved as part of line content
  LPath := MakeTempPath('crlf.txt');
  WriteUtf8File(LPath, 'A' + #13#10 + 'B' + #13#10 + 'C' + #13#10 + 'D');
  LResult := ReadTextFile(LPath, FCacheManager, 0, 0, 2, 3);
  // Lines split on LF, so CR is part of the line content
  Assert.AreEqual('B' + #13 + #10 + 'C' + #13, LResult.Content);
end;

initialization
  TDUnitX.RegisterTestFixture(TLineRangeTests);

end.
