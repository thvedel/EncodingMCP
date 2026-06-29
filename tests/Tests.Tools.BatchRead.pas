unit Tests.Tools.BatchRead;

/// <summary>
///   Tests for the read_text_files (batch-read) MCP tool.
/// </summary>

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  Encoding.CacheManager;

type
  [TestFixture]
  TBatchReadTests = class
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
    procedure BatchRead_SingleFile;
    [Test]
    procedure BatchRead_MultipleFiles;
    [Test]
    procedure BatchRead_OneFileFails_OthersSucceed;
    [Test]
    procedure BatchRead_MetadataOnly_NoContent;
    [Test]
    procedure BatchRead_WithHeadParam;
    [Test]
    procedure BatchRead_EmptyArray_Raises;
    [Test]
    procedure BatchRead_SearchText;
  end;

implementation

uses
  System.IOUtils,
  System.JSON,
  System.Generics.Collections,
  MCP.Tools,
  Tools.BatchRead;

{ TBatchReadTests }

procedure TBatchReadTests.Setup;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'BatchReadTest_' +
    FormatDateTime('yyyymmdd_hhnnsszzz', Now));
  TDirectory.CreateDirectory(FTempDir);
  FCacheManager := TCacheManager.Create;
end;

procedure TBatchReadTests.Teardown;
begin
  FCacheManager.Free;
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

function TBatchReadTests.MakeTempPath(const AFileName: string): string;
begin
  Result := TPath.Combine(FTempDir, AFileName);
end;

procedure TBatchReadTests.WriteUtf8File(const APath, AContent: string);
var
  LBytes: TBytes;
begin
  LBytes := TEncoding.UTF8.GetPreamble + TEncoding.UTF8.GetBytes(AContent);
  TFile.WriteAllBytes(APath, LBytes);
end;

function ExecuteBatchRead(ACacheManager: TCacheManager;
  AFilesArr: TJSONArray): TJSONObject;
var
  LTool: TBatchReadTool;
  LArgs, LResult: TJSONObject;
  LContent: TJSONArray;
  LText: string;
begin
  LTool := TBatchReadTool.Create(ACacheManager);
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

procedure TBatchReadTests.BatchRead_SingleFile;
var
  LPath: string;
  LFiles: TJSONArray;
  LFileObj, LJson, LResultObj: TJSONObject;
  LResults: TJSONArray;
begin
  LPath := MakeTempPath('single.txt');
  WriteUtf8File(LPath, 'hello world');
  LFiles := TJSONArray.Create;
  LFileObj := TJSONObject.Create;
  LFileObj.AddPair('path', LPath);
  LFiles.AddElement(LFileObj);
  LJson := ExecuteBatchRead(FCacheManager, LFiles);
  LFiles.Free;
  try
    Assert.AreEqual(1, LJson.GetValue<Integer>('totalFiles'));
    Assert.AreEqual(1, LJson.GetValue<Integer>('succeeded'));
    Assert.AreEqual(0, LJson.GetValue<Integer>('failed'));
    LResults := LJson.GetValue<TJSONArray>('results');
    Assert.AreEqual(1, LResults.Count);
    LResultObj := LResults.Items[0] as TJSONObject;
    Assert.AreEqual('hello world', LResultObj.GetValue<string>('content'));
  finally
    LJson.Free;
  end;
end;

procedure TBatchReadTests.BatchRead_MultipleFiles;
var
  LFiles: TJSONArray;
  LF1, LF2, LF3, LJson: TJSONObject;
  LResults: TJSONArray;
begin
  WriteUtf8File(MakeTempPath('a.txt'), 'aaa');
  WriteUtf8File(MakeTempPath('b.txt'), 'bbb');
  WriteUtf8File(MakeTempPath('c.txt'), 'ccc');
  LFiles := TJSONArray.Create;
  LF1 := TJSONObject.Create; LF1.AddPair('path', MakeTempPath('a.txt')); LFiles.AddElement(LF1);
  LF2 := TJSONObject.Create; LF2.AddPair('path', MakeTempPath('b.txt')); LFiles.AddElement(LF2);
  LF3 := TJSONObject.Create; LF3.AddPair('path', MakeTempPath('c.txt')); LFiles.AddElement(LF3);
  LJson := ExecuteBatchRead(FCacheManager, LFiles);
  LFiles.Free;
  try
    Assert.AreEqual(3, LJson.GetValue<Integer>('totalFiles'));
    Assert.AreEqual(3, LJson.GetValue<Integer>('succeeded'));
    LResults := LJson.GetValue<TJSONArray>('results');
    Assert.AreEqual(3, LResults.Count);
    Assert.AreEqual('aaa', (LResults.Items[0] as TJSONObject).GetValue<string>('content'));
    Assert.AreEqual('bbb', (LResults.Items[1] as TJSONObject).GetValue<string>('content'));
    Assert.AreEqual('ccc', (LResults.Items[2] as TJSONObject).GetValue<string>('content'));
  finally
    LJson.Free;
  end;
end;

procedure TBatchReadTests.BatchRead_OneFileFails_OthersSucceed;
var
  LFiles: TJSONArray;
  LF1, LF2, LJson: TJSONObject;
  LResults: TJSONArray;
  LR2: TJSONObject;
begin
  WriteUtf8File(MakeTempPath('good.txt'), 'ok');
  // 'missing.txt' does not exist
  LFiles := TJSONArray.Create;
  LF1 := TJSONObject.Create; LF1.AddPair('path', MakeTempPath('good.txt')); LFiles.AddElement(LF1);
  LF2 := TJSONObject.Create; LF2.AddPair('path', MakeTempPath('missing.txt')); LFiles.AddElement(LF2);
  LJson := ExecuteBatchRead(FCacheManager, LFiles);
  LFiles.Free;
  try
    Assert.AreEqual(2, LJson.GetValue<Integer>('totalFiles'));
    Assert.AreEqual(1, LJson.GetValue<Integer>('succeeded'));
    Assert.AreEqual(1, LJson.GetValue<Integer>('failed'));
    LResults := LJson.GetValue<TJSONArray>('results');
    // First file succeeded
    Assert.AreEqual('ok', (LResults.Items[0] as TJSONObject).GetValue<string>('content'));
    // Second file has error
    LR2 := LResults.Items[1] as TJSONObject;
    Assert.IsNotNull(LR2.GetValue('error'), 'Missing file should have error field');
  finally
    LJson.Free;
  end;
end;

procedure TBatchReadTests.BatchRead_MetadataOnly_NoContent;
var
  LFiles: TJSONArray;
  LFileObj, LJson, LResultObj: TJSONObject;
begin
  WriteUtf8File(MakeTempPath('meta.txt'), 'some content');
  LFiles := TJSONArray.Create;
  LFileObj := TJSONObject.Create;
  LFileObj.AddPair('path', MakeTempPath('meta.txt'));
  LFileObj.AddPair('metadataOnly', TJSONBool.Create(True));
  LFiles.AddElement(LFileObj);
  LJson := ExecuteBatchRead(FCacheManager, LFiles);
  LFiles.Free;
  try
    LResultObj := LJson.GetValue<TJSONArray>('results').Items[0] as TJSONObject;
    Assert.IsNull(LResultObj.GetValue('content'),
      'metadataOnly should exclude content');
    Assert.IsTrue(LResultObj.GetValue<Integer>('totalLines') > 0);
  finally
    LJson.Free;
  end;
end;

procedure TBatchReadTests.BatchRead_WithHeadParam;
var
  LFiles: TJSONArray;
  LFileObj, LJson, LResultObj: TJSONObject;
  LContent: string;
begin
  WriteUtf8File(MakeTempPath('lines.txt'), 'line1' + #10 + 'line2' + #10 + 'line3');
  LFiles := TJSONArray.Create;
  LFileObj := TJSONObject.Create;
  LFileObj.AddPair('path', MakeTempPath('lines.txt'));
  LFileObj.AddPair('head', TJSONNumber.Create(1));
  LFiles.AddElement(LFileObj);
  LJson := ExecuteBatchRead(FCacheManager, LFiles);
  LFiles.Free;
  try
    LResultObj := LJson.GetValue<TJSONArray>('results').Items[0] as TJSONObject;
    LContent := LResultObj.GetValue<string>('content');
    Assert.AreEqual('line1', LContent);
    Assert.AreEqual(1, LResultObj.GetValue<Integer>('returnedLines'));
    Assert.AreEqual(3, LResultObj.GetValue<Integer>('totalLines'));
  finally
    LJson.Free;
  end;
end;

procedure TBatchReadTests.BatchRead_EmptyArray_Raises;
var
  LRaised: Boolean;
  LFiles: TJSONArray;
begin
  LRaised := False;
  LFiles := TJSONArray.Create;
  try
    ExecuteBatchRead(FCacheManager, LFiles).Free;
  except
    LRaised := True;
  end;
  LFiles.Free;
  Assert.IsTrue(LRaised, 'Empty files array should raise');
end;

procedure TBatchReadTests.BatchRead_SearchText;
var
  LFiles: TJSONArray;
  LFileObj, LJson, LResultObj: TJSONObject;
begin
  WriteUtf8File(MakeTempPath('search.txt'),
    'alpha' + #10 + 'beta' + #10 + 'gamma' + #10 + 'beta again');
  LFiles := TJSONArray.Create;
  LFileObj := TJSONObject.Create;
  LFileObj.AddPair('path', MakeTempPath('search.txt'));
  LFileObj.AddPair('searchText', 'beta');
  LFiles.AddElement(LFileObj);
  LJson := ExecuteBatchRead(FCacheManager, LFiles);
  LFiles.Free;
  try
    LResultObj := LJson.GetValue<TJSONArray>('results').Items[0] as TJSONObject;
    Assert.AreEqual(2, LResultObj.GetValue<Integer>('matchCount'));
    Assert.AreEqual(2, LResultObj.GetValue<Integer>('returnedLines'));
  finally
    LJson.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TBatchReadTests);

end.
