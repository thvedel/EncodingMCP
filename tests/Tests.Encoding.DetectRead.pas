unit Tests.Encoding.DetectRead;

/// <summary>
///   Tests that detect_encoding and read_text_file agree (same resolution,
///   complete file), the ASCII write advice and the binary DFM guard on
///   read, batch read, edit, write and detect.
/// </summary>

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.JSON,
  MCP.Tools,
  Encoding.CacheManager;

type
  [TestFixture]
  TDetectReadTests = class
  strict private
    FTempDir: string;
    FCacheManager: TCacheManager;
    function MakeTempPath(const AName: string): string;
    function BinaryDfmBytes: TBytes;
    function RunTool(const ATool: IMcpTool; AArgs: TJSONObject;
      out AIsError: Boolean): TJSONObject;
    function PathArgs(const APath: string): TJSONObject;
  public
    [Setup]
    procedure Setup;
    [Teardown]
    procedure Teardown;

    [Test]
    procedure IsBinaryDfm_RawSignature_True;
    [Test]
    procedure IsBinaryDfm_ResourceHeader_True;
    [Test]
    procedure IsBinaryDfm_TextForm_False;
    [Test]
    procedure IsBinaryDfm_ShortOrEmpty_False;
    [Test]
    procedure Read_BinaryDfm_ReturnsFormatError;
    [Test]
    procedure BatchRead_BinaryDfm_ReportsPerFile;
    [Test]
    procedure Edit_BinaryDfm_ReturnsFormatError;
    [Test]
    procedure Write_BinaryDfm_WithoutForce_RefusesAndKeepsFile;
    [Test]
    procedure Write_BinaryDfm_WithForce_ReplacesAndWarns;
    [Test]
    procedure Detect_BinaryDfm_ReportsFormatWithoutError;
    [Test]
    procedure DetectAndRead_AgreeOnPatternOverride;
    [Test]
    procedure DetectAndRead_AgreeOnFileOverride;
    [Test]
    procedure Detect_LateNonAsciiByte_IsNotAscii;
    [Test]
    procedure DetectAndRead_Ascii_IncludeWriteRecommendation;
    [Test]
    procedure DetectAndRead_NonAscii_HaveNoWriteRecommendation;
  end;

implementation

uses
  System.IOUtils,
  System.Generics.Collections,
  Encoding.Types,
  Encoding.Cache,
  Encoding.Detector,
  Encoding.Workspace,
  FileIO.Reader,
  Tools.ReadFile,
  Tools.BatchRead,
  Tools.EditFile,
  Tools.WriteFile,
  Tools.DetectEncoding;

{ TDetectReadTests }

procedure TDetectReadTests.Setup;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'DetectReadTests_' +
    FormatDateTime('yyyymmddhhnnsszzz', Now));
  TDirectory.CreateDirectory(FTempDir);
  TDirectory.CreateDirectory(TPath.Combine(FTempDir, '.git'));
  SetWorkspaceRoots([FTempDir]);
  FCacheManager := TCacheManager.Create;
end;

procedure TDetectReadTests.Teardown;
begin
  FreeAndNil(FCacheManager);
  SetWorkspaceRoots([]);
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

function TDetectReadTests.MakeTempPath(const AName: string): string;
begin
  Result := TPath.Combine(FTempDir, AName);
end;

function TDetectReadTests.BinaryDfmBytes: TBytes;
begin
  // 'TPF0' + TForm1 class name + Form1 object name + a few property bytes
  Result := TBytes.Create($54, $50, $46, $30, $06, $54, $46, $6F, $72, $6D,
    $31, $05, $46, $6F, $72, $6D, $31, $04, $4C, $65, $66, $74, $02, $00, $00, $00);
end;

function TDetectReadTests.PathArgs(const APath: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('path', APath);
end;

function TDetectReadTests.RunTool(const ATool: IMcpTool; AArgs: TJSONObject;
  out AIsError: Boolean): TJSONObject;
var
  LResult: TJSONObject;
  LText: string;
begin
  try
    LResult := ATool.Execute(AArgs);
    try
      AIsError := LResult.GetValue<Boolean>('isError', False);
      LText := LResult.GetValue<TJSONArray>('content').Items[0].GetValue<string>('text');
      Result := TJSONObject.ParseJSONValue(LText) as TJSONObject;
    finally
      LResult.Free;
    end;
  finally
    AArgs.Free;
  end;
end;

procedure TDetectReadTests.IsBinaryDfm_RawSignature_True;
begin
  Assert.IsTrue(IsBinaryDfm(BinaryDfmBytes));
end;

procedure TDetectReadTests.IsBinaryDfm_ResourceHeader_True;
var
  LBytes: TBytes;
begin
  // $FF $0A $00 + 'TFORM1' + #0 + flags + size, then the TPF0 stream
  LBytes := TBytes.Create($FF, $0A, $00, $54, $46, $4F, $52, $4D, $31, $00,
    $30, $10, $1A, $00, $00, $00) + BinaryDfmBytes;
  Assert.IsTrue(IsBinaryDfm(LBytes));
end;

procedure TDetectReadTests.IsBinaryDfm_TextForm_False;
begin
  Assert.IsFalse(IsBinaryDfm(TEncoding.ASCII.GetBytes(
    'object Form1: TForm1'#13#10'  Left = 0'#13#10'end'#13#10)));
end;

procedure TDetectReadTests.IsBinaryDfm_ShortOrEmpty_False;
begin
  Assert.IsFalse(IsBinaryDfm(nil));
  Assert.IsFalse(IsBinaryDfm(TBytes.Create($54, $50, $46)));
  Assert.IsFalse(IsBinaryDfm(TBytes.Create($FF, $0A, $00, $41)));
end;

procedure TDetectReadTests.Read_BinaryDfm_ReturnsFormatError;
var
  LPath: string;
  LJson: TJSONObject;
  LIsError: Boolean;
begin
  LPath := MakeTempPath('Form1.dfm');
  TFile.WriteAllBytes(LPath, BinaryDfmBytes);
  LJson := RunTool(TReadFileTool.Create(FCacheManager), PathArgs(LPath), LIsError);
  try
    Assert.IsTrue(LIsError, 'isError expected');
    Assert.AreEqual(FORMAT_BINARY_DFM, LJson.GetValue<string>('format'));
    Assert.IsNotNull(LJson.GetValue('error'));
  finally
    LJson.Free;
  end;
end;

procedure TDetectReadTests.BatchRead_BinaryDfm_ReportsPerFile;
var
  LBinary, LText: string;
  LArgs, LFile: TJSONObject;
  LFiles, LResults: TJSONArray;
  LJson, LFirst, LSecond: TJSONObject;
  LIsError: Boolean;
begin
  LBinary := MakeTempPath('Form1.dfm');
  LText := MakeTempPath('Unit1.pas');
  TFile.WriteAllBytes(LBinary, BinaryDfmBytes);
  TFile.WriteAllBytes(LText, TEncoding.ASCII.GetBytes('unit Unit1;'#13#10));
  LArgs := TJSONObject.Create;
  LFiles := TJSONArray.Create;
  LArgs.AddPair('files', LFiles);
  LFile := TJSONObject.Create;
  LFile.AddPair('path', LBinary);
  LFiles.AddElement(LFile);
  LFile := TJSONObject.Create;
  LFile.AddPair('path', LText);
  LFiles.AddElement(LFile);
  LJson := RunTool(TBatchReadTool.Create(FCacheManager), LArgs, LIsError);
  try
    LResults := LJson.GetValue<TJSONArray>('results');
    LFirst := LResults.Items[0] as TJSONObject;
    LSecond := LResults.Items[1] as TJSONObject;
    Assert.AreEqual(FORMAT_BINARY_DFM, LFirst.GetValue<string>('format'));
    Assert.IsNotNull(LFirst.GetValue('error'));
    Assert.AreEqual(FORMAT_TEXT, LSecond.GetValue<string>('format'));
    Assert.IsNull(LSecond.GetValue('error'));
  finally
    LJson.Free;
  end;
end;

procedure TDetectReadTests.Edit_BinaryDfm_ReturnsFormatError;
var
  LPath: string;
  LArgs, LJson: TJSONObject;
  LIsError: Boolean;
begin
  LPath := MakeTempPath('Form1.dfm');
  TFile.WriteAllBytes(LPath, BinaryDfmBytes);
  LArgs := PathArgs(LPath);
  LArgs.AddPair('oldText', 'Form1');
  LArgs.AddPair('newText', 'Form2');
  LJson := RunTool(TEditFileTool.Create(FCacheManager), LArgs, LIsError);
  try
    Assert.IsTrue(LIsError, 'isError expected');
    Assert.AreEqual(FORMAT_BINARY_DFM, LJson.GetValue<string>('format'));
  finally
    LJson.Free;
  end;
  Assert.AreEqual<TBytes>(BinaryDfmBytes, TFile.ReadAllBytes(LPath));
end;

procedure TDetectReadTests.Write_BinaryDfm_WithoutForce_RefusesAndKeepsFile;
var
  LPath: string;
  LArgs, LJson: TJSONObject;
  LIsError: Boolean;
begin
  LPath := MakeTempPath('Form1.dfm');
  TFile.WriteAllBytes(LPath, BinaryDfmBytes);
  LArgs := PathArgs(LPath);
  LArgs.AddPair('content', 'object Form1: TForm1'#13#10'end'#13#10);
  LJson := RunTool(TWriteFileTool.Create(FCacheManager), LArgs, LIsError);
  try
    Assert.IsTrue(LIsError, 'isError expected');
    Assert.AreEqual(FORMAT_BINARY_DFM, LJson.GetValue<string>('format'));
  finally
    LJson.Free;
  end;
  Assert.AreEqual<TBytes>(BinaryDfmBytes, TFile.ReadAllBytes(LPath));
end;

procedure TDetectReadTests.Write_BinaryDfm_WithForce_ReplacesAndWarns;
var
  LPath, LContent: string;
  LArgs, LJson: TJSONObject;
  LWarnings: TJSONArray;
  LIsError: Boolean;
begin
  LPath := MakeTempPath('Form1.dfm');
  TFile.WriteAllBytes(LPath, BinaryDfmBytes);
  LContent := 'object Form1: TForm1'#13#10'end'#13#10;
  LArgs := PathArgs(LPath);
  LArgs.AddPair('content', LContent);
  LArgs.AddPair('force', TJSONBool.Create(True));
  LJson := RunTool(TWriteFileTool.Create(FCacheManager), LArgs, LIsError);
  try
    Assert.IsFalse(LIsError, 'Forced write must succeed');
    LWarnings := LJson.GetValue<TJSONArray>('warnings');
    Assert.IsNotNull(LWarnings, 'warnings expected');
    Assert.Contains(LWarnings.Items[0].Value, FORMAT_BINARY_DFM);
  finally
    LJson.Free;
  end;
  Assert.IsFalse(IsBinaryDfm(TFile.ReadAllBytes(LPath)));
  Assert.Contains(TFile.ReadAllText(LPath), 'object Form1: TForm1');
end;

procedure TDetectReadTests.Detect_BinaryDfm_ReportsFormatWithoutError;
var
  LPath: string;
  LJson: TJSONObject;
  LIsError: Boolean;
begin
  LPath := MakeTempPath('Form1.dfm');
  TFile.WriteAllBytes(LPath, BinaryDfmBytes);
  LJson := RunTool(TDetectEncodingTool.Create(FCacheManager), PathArgs(LPath), LIsError);
  try
    Assert.IsFalse(LIsError, 'detect_encoding reports, it does not fail');
    Assert.AreEqual(FORMAT_BINARY_DFM, LJson.GetValue<string>('format'));
    Assert.IsNull(LJson.GetValue('encoding'));
  finally
    LJson.Free;
  end;
end;

procedure TDetectReadTests.DetectAndRead_AgreeOnPatternOverride;
var
  LPath: string;
  LDetect, LRead: TJSONObject;
  LIsError: Boolean;
begin
  TFile.WriteAllText(TPath.Combine(FTempDir, CACHE_FILE_NAME),
    '{"version":1,"files":{},"overrides":{"*.dfm":"Windows-1252"}}', TEncoding.UTF8);
  LPath := MakeTempPath('Form1.dfm');
  TFile.WriteAllBytes(LPath, TEncoding.ASCII.GetBytes('object Form1: TForm1'#13#10'end'#13#10));
  LDetect := RunTool(TDetectEncodingTool.Create(FCacheManager), PathArgs(LPath), LIsError);
  try
    LRead := RunTool(TReadFileTool.Create(FCacheManager), PathArgs(LPath), LIsError);
    try
      Assert.AreEqual('Windows-1252', LDetect.GetValue<string>('encoding'));
      Assert.AreEqual(LRead.GetValue<string>('encoding'), LDetect.GetValue<string>('encoding'));
      Assert.AreEqual(LRead.GetValue<string>('source'), LDetect.GetValue<string>('source'));
      Assert.AreEqual(LRead.GetValue<Boolean>('hasBom'), LDetect.GetValue<Boolean>('hasBom'));
    finally
      LRead.Free;
    end;
  finally
    LDetect.Free;
  end;
end;

procedure TDetectReadTests.DetectAndRead_AgreeOnFileOverride;
var
  LPath: string;
  LDetect, LRead: TJSONObject;
  LIsError: Boolean;
  LCache: TEncodingCache;
  LRelative: string;
  LEntry: TCacheEntry;
begin
  // Regression (bug 9): detect_encoding ignored a per-file override and
  // reported ASCII with confidence 0.99 while read_text_file said Windows-1252.
  LPath := MakeTempPath('Form1.dfm');
  TFile.WriteAllBytes(LPath, TEncoding.ASCII.GetBytes('object Form1: TForm1'#13#10'end'#13#10));
  FCacheManager.Resolve(LPath, LCache, LRelative);
  LEntry := Default(TCacheEntry);
  LEntry.EncodingId := TEncodingId.Windows1252;
  LEntry.Manual := True;
  LCache.Put(LRelative, LEntry);

  LDetect := RunTool(TDetectEncodingTool.Create(FCacheManager), PathArgs(LPath), LIsError);
  try
    LRead := RunTool(TReadFileTool.Create(FCacheManager), PathArgs(LPath), LIsError);
    try
      Assert.AreEqual('Windows-1252', LDetect.GetValue<string>('encoding'));
      Assert.AreEqual('fileOverride', LDetect.GetValue<string>('source'));
      Assert.AreEqual(1.0, LDetect.GetValue<Double>('confidence'), 0.0001);
      Assert.AreEqual(LRead.GetValue<string>('encoding'), LDetect.GetValue<string>('encoding'));
      Assert.AreEqual(LRead.GetValue<string>('source'), LDetect.GetValue<string>('source'));
    finally
      LRead.Free;
    end;
  finally
    LDetect.Free;
  end;
end;

procedure TDetectReadTests.Detect_LateNonAsciiByte_IsNotAscii;
var
  LPath: string;
  LBytes: TBytes;
  LDetect, LRead: TJSONObject;
  LIsError: Boolean;
begin
  // The first non-ASCII byte lies beyond the former 64 KB sample window.
  LBytes := TEncoding.ASCII.GetBytes(StringOfChar('a', 70000) + #13#10'// x');
  LBytes := LBytes + TBytes.Create($F8) + TEncoding.ASCII.GetBytes('x'#13#10);
  LPath := MakeTempPath('Big.pas');
  TFile.WriteAllBytes(LPath, LBytes);
  LDetect := RunTool(TDetectEncodingTool.Create(FCacheManager), PathArgs(LPath), LIsError);
  try
    LRead := RunTool(TReadFileTool.Create(FCacheManager), PathArgs(LPath), LIsError);
    try
      Assert.AreNotEqual('ASCII', LDetect.GetValue<string>('encoding'));
      Assert.AreEqual(LRead.GetValue<string>('encoding'), LDetect.GetValue<string>('encoding'));
      Assert.AreEqual(Int64(Length(LBytes)), LDetect.GetValue<Int64>('bytesRead'));
    finally
      LRead.Free;
    end;
  finally
    LDetect.Free;
  end;
end;

procedure TDetectReadTests.DetectAndRead_Ascii_IncludeWriteRecommendation;
var
  LPath: string;
  LDetect, LRead: TJSONObject;
  LIsError: Boolean;
begin
  LPath := MakeTempPath('Unit1.pas');
  TFile.WriteAllBytes(LPath, TEncoding.ASCII.GetBytes('unit Unit1;'#13#10));
  LDetect := RunTool(TDetectEncodingTool.Create(FCacheManager), PathArgs(LPath), LIsError);
  try
    LRead := RunTool(TReadFileTool.Create(FCacheManager), PathArgs(LPath), LIsError);
    try
      Assert.AreEqual('ASCII', LDetect.GetValue<string>('encoding'));
      Assert.AreEqual('Windows-1252', LDetect.GetValue<string>('writeRecommendation'));
      Assert.AreEqual('Windows-1252', LRead.GetValue<string>('writeRecommendation'));
      Assert.IsNotNull(LDetect.GetValue('note'));
      Assert.IsNotNull(LRead.GetValue('note'));
    finally
      LRead.Free;
    end;
  finally
    LDetect.Free;
  end;
end;

procedure TDetectReadTests.DetectAndRead_NonAscii_HaveNoWriteRecommendation;
var
  LPath: string;
  LDetect, LRead: TJSONObject;
  LIsError: Boolean;
begin
  LPath := MakeTempPath('Unit1.pas');
  TFile.WriteAllBytes(LPath, TEncoding.UTF8.GetPreamble +
    TEncoding.UTF8.GetBytes('// ' + Char($F8) + #13#10));
  LDetect := RunTool(TDetectEncodingTool.Create(FCacheManager), PathArgs(LPath), LIsError);
  try
    LRead := RunTool(TReadFileTool.Create(FCacheManager), PathArgs(LPath), LIsError);
    try
      Assert.AreEqual('UTF-8', LDetect.GetValue<string>('encoding'));
      Assert.IsNull(LDetect.GetValue('writeRecommendation'));
      Assert.IsNull(LRead.GetValue('writeRecommendation'));
    finally
      LRead.Free;
    end;
  finally
    LDetect.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TDetectReadTests);

end.
