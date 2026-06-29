unit Tests.Tools.BatchWrite;

/// <summary>
///   Tests for the write_text_files (batch-write) MCP tool.
/// </summary>

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  Encoding.CacheManager;

type
  [TestFixture]
  TBatchWriteTests = class
  strict private
    FTempDir: string;
    FCacheManager: TCacheManager;
    function MakeTempPath(const AFileName: string): string;
  public
    [Setup]
    procedure Setup;
    [Teardown]
    procedure Teardown;

    [Test]
    procedure BatchWrite_SingleFile;
    [Test]
    procedure BatchWrite_MultipleFiles;
    [Test]
    procedure BatchWrite_OneFileFails_OthersSucceed;
    [Test]
    procedure BatchWrite_CreatesNewFile;
    [Test]
    procedure BatchWrite_EmptyArray_Raises;
    [Test]
    procedure BatchWrite_WithEncodingOverride;
  end;

implementation

uses
  System.IOUtils,
  System.JSON,
  System.Generics.Collections,
  Encoding.Types,
  MCP.Tools,
  Tools.BatchWrite,
  FileIO.Reader;

{ TBatchWriteTests }

procedure TBatchWriteTests.Setup;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'BatchWriteTest_' +
    FormatDateTime('yyyymmdd_hhnnsszzz', Now));
  TDirectory.CreateDirectory(FTempDir);
  TDirectory.CreateDirectory(TPath.Combine(FTempDir, '.git'));
  FCacheManager := TCacheManager.Create;
end;

procedure TBatchWriteTests.Teardown;
begin
  FCacheManager.Free;
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

function TBatchWriteTests.MakeTempPath(const AFileName: string): string;
begin
  Result := TPath.Combine(FTempDir, AFileName);
end;

function ExecuteBatchWrite(ACacheManager: TCacheManager;
  AFilesArr: TJSONArray): TJSONObject;
var
  LTool: TBatchWriteTool;
  LArgs, LResult: TJSONObject;
  LContent: TJSONArray;
  LText: string;
begin
  LTool := TBatchWriteTool.Create(ACacheManager);
  try
    LArgs := TJSONObject.Create;
    try
      LArgs.AddPair('files', AFilesArr.Clone as TJSONArray);
      LResult := LTool.Execute(LArgs);
      try
        LContent := LResult.GetValue<TJSONArray>('content');
        LText := LContent.Items[0].GetValue<string>('text');
        Result := TJSONObject.ParseJSONValue(LText) as TJSONObject;
      finally
        LResult.Free;
      end;
    finally
      LArgs.Free;
    end;
  finally
    // ref-counted
  end;
end;

procedure TBatchWriteTests.BatchWrite_SingleFile;
var
  LPath: string;
  LFiles: TJSONArray;
  LFileObj, LJson: TJSONObject;
  LReadResult: TReadResult;
begin
  LPath := MakeTempPath('single.txt');
  LFiles := TJSONArray.Create;
  LFileObj := TJSONObject.Create;
  LFileObj.AddPair('path', LPath);
  LFileObj.AddPair('content', 'hello batch');
  LFiles.AddElement(LFileObj);
  LJson := ExecuteBatchWrite(FCacheManager, LFiles);
  LFiles.Free;
  try
    Assert.AreEqual(1, LJson.GetValue<Integer>('totalFiles'));
    Assert.AreEqual(1, LJson.GetValue<Integer>('succeeded'));
    Assert.AreEqual(0, LJson.GetValue<Integer>('failed'));
  finally
    LJson.Free;
  end;
  LReadResult := ReadTextFile(LPath, FCacheManager);
  Assert.AreEqual('hello batch', LReadResult.Content);
end;

procedure TBatchWriteTests.BatchWrite_MultipleFiles;
var
  LFiles: TJSONArray;
  LF1, LF2, LJson: TJSONObject;
begin
  LFiles := TJSONArray.Create;
  LF1 := TJSONObject.Create;
  LF1.AddPair('path', MakeTempPath('a.txt'));
  LF1.AddPair('content', 'aaa');
  LFiles.AddElement(LF1);
  LF2 := TJSONObject.Create;
  LF2.AddPair('path', MakeTempPath('b.txt'));
  LF2.AddPair('content', 'bbb');
  LFiles.AddElement(LF2);
  LJson := ExecuteBatchWrite(FCacheManager, LFiles);
  LFiles.Free;
  try
    Assert.AreEqual(2, LJson.GetValue<Integer>('succeeded'));
  finally
    LJson.Free;
  end;
  Assert.AreEqual('aaa', ReadTextFile(MakeTempPath('a.txt'), FCacheManager).Content);
  Assert.AreEqual('bbb', ReadTextFile(MakeTempPath('b.txt'), FCacheManager).Content);
end;

procedure TBatchWriteTests.BatchWrite_OneFileFails_OthersSucceed;
var
  LFiles: TJSONArray;
  LF1, LF2, LJson: TJSONObject;
  LResults: TJSONArray;
begin
  LFiles := TJSONArray.Create;
  // Good file
  LF1 := TJSONObject.Create;
  LF1.AddPair('path', MakeTempPath('good.txt'));
  LF1.AddPair('content', 'ok');
  LFiles.AddElement(LF1);
  // Bad file: createIfMissing=false on nonexistent
  LF2 := TJSONObject.Create;
  LF2.AddPair('path', MakeTempPath('sub\nonexist.txt'));
  LF2.AddPair('content', 'x');
  LF2.AddPair('createIfMissing', TJSONBool.Create(False));
  LFiles.AddElement(LF2);
  LJson := ExecuteBatchWrite(FCacheManager, LFiles);
  LFiles.Free;
  try
    Assert.AreEqual(1, LJson.GetValue<Integer>('succeeded'));
    Assert.AreEqual(1, LJson.GetValue<Integer>('failed'));
    LResults := LJson.GetValue<TJSONArray>('results');
    Assert.IsNotNull((LResults.Items[1] as TJSONObject).GetValue('error'));
  finally
    LJson.Free;
  end;
  // Good file was written
  Assert.AreEqual('ok', ReadTextFile(MakeTempPath('good.txt'), FCacheManager).Content);
end;

procedure TBatchWriteTests.BatchWrite_CreatesNewFile;
var
  LPath: string;
  LFiles: TJSONArray;
  LFileObj, LJson: TJSONObject;
  LResults: TJSONArray;
begin
  LPath := MakeTempPath('newfile.txt');
  Assert.IsFalse(TFile.Exists(LPath));
  LFiles := TJSONArray.Create;
  LFileObj := TJSONObject.Create;
  LFileObj.AddPair('path', LPath);
  LFileObj.AddPair('content', 'brand new');
  LFiles.AddElement(LFileObj);
  LJson := ExecuteBatchWrite(FCacheManager, LFiles);
  LFiles.Free;
  try
    LResults := LJson.GetValue<TJSONArray>('results');
    Assert.IsTrue((LResults.Items[0] as TJSONObject).GetValue<Boolean>('created'));
  finally
    LJson.Free;
  end;
  Assert.IsTrue(TFile.Exists(LPath));
end;

procedure TBatchWriteTests.BatchWrite_EmptyArray_Raises;
var
  LRaised: Boolean;
  LFiles: TJSONArray;
begin
  LRaised := False;
  LFiles := TJSONArray.Create;
  try
    ExecuteBatchWrite(FCacheManager, LFiles).Free;
  except
    LRaised := True;
  end;
  LFiles.Free;
  Assert.IsTrue(LRaised, 'Empty files array should raise');
end;

procedure TBatchWriteTests.BatchWrite_WithEncodingOverride;
var
  LPath: string;
  LFiles: TJSONArray;
  LFileObj, LJson: TJSONObject;
  LResults: TJSONArray;
  LResultObj: TJSONObject;
begin
  LPath := MakeTempPath('encoded.txt');
  LFiles := TJSONArray.Create;
  LFileObj := TJSONObject.Create;
  LFileObj.AddPair('path', LPath);
  LFileObj.AddPair('content', 'test');
  LFileObj.AddPair('encoding', 'Windows-1252');
  LFileObj.AddPair('hasBom', TJSONBool.Create(False));
  LFiles.AddElement(LFileObj);
  LJson := ExecuteBatchWrite(FCacheManager, LFiles);
  LFiles.Free;
  try
    LResults := LJson.GetValue<TJSONArray>('results');
    LResultObj := LResults.Items[0] as TJSONObject;
    Assert.AreEqual('Windows-1252', LResultObj.GetValue<string>('encoding'));
    Assert.IsFalse(LResultObj.GetValue<Boolean>('hasBom'));
  finally
    LJson.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TBatchWriteTests);

end.
