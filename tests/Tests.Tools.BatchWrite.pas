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
    [Test]
    procedure BatchWrite_AsciiUpgrade_ReportsUpgradeAndWarning;
    [Test]
    procedure BatchWrite_UnrepresentableChars_ReportsPerFileError;
    [Test]
    procedure BatchWrite_DryRun_ReportsWithoutWriting;
    [Test]
    procedure ValidateArguments_RejectsUnknownName;
    [Test]
    procedure ValidateArguments_RejectsWrongType;
    [Test]
    procedure ValidateArguments_RejectsUnknownNestedName;
    [Test]
    procedure ValidateArguments_AcceptsValidArguments;
    [Test]
    procedure ValidateArguments_TreatsNullAsAbsent;
    [Test]
    procedure Execute_MissingFiles_RaisesInvalidArgument;
    [Test]
    procedure Execute_EmptyFiles_RaisesInvalidArgument;
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

function MakeFileEntry(const APath, AContent: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('path', APath);
  Result.AddPair('content', AContent);
end;

procedure TBatchWriteTests.BatchWrite_AsciiUpgrade_ReportsUpgradeAndWarning;
var
  LPath: string;
  LFiles: TJSONArray;
  LJson, LResultObj: TJSONObject;
begin
  LPath := MakeTempPath('ascii.pas');
  TFile.WriteAllBytes(LPath, TEncoding.ASCII.GetBytes('// X'#13#10));
  LFiles := TJSONArray.Create;
  LFiles.AddElement(MakeFileEntry(LPath, '// '#$00F8#13#10));
  LJson := ExecuteBatchWrite(FCacheManager, LFiles);
  LFiles.Free;
  try
    LResultObj := LJson.GetValue<TJSONArray>('results').Items[0] as TJSONObject;
    Assert.AreEqual('Windows-1252', LResultObj.GetValue<string>('encoding'));
    Assert.AreEqual('ASCII', LResultObj.GetValue<string>('upgradedFrom'));
    Assert.IsTrue(LResultObj.GetValue<TJSONArray>('warnings').Count > 0);
  finally
    LJson.Free;
  end;
  Assert.AreEqual(Byte($F8), TFile.ReadAllBytes(LPath)[3]);
end;

procedure TBatchWriteTests.BatchWrite_UnrepresentableChars_ReportsPerFileError;
var
  LPath: string;
  LFiles: TJSONArray;
  LEntry, LJson, LResultObj: TJSONObject;
begin
  LPath := MakeTempPath('greek.txt');
  LFiles := TJSONArray.Create;
  LEntry := MakeFileEntry(LPath, 'x'#$0394);
  LEntry.AddPair('encoding', 'Windows-1252');
  LFiles.AddElement(LEntry);
  LFiles.AddElement(MakeFileEntry(MakeTempPath('fine.txt'), 'fine'));
  LJson := ExecuteBatchWrite(FCacheManager, LFiles);
  LFiles.Free;
  try
    Assert.AreEqual(1, LJson.GetValue<Integer>('succeeded'));
    Assert.AreEqual(1, LJson.GetValue<Integer>('failed'));
    LResultObj := LJson.GetValue<TJSONArray>('results').Items[0] as TJSONObject;
    Assert.AreEqual(1, LResultObj.GetValue<Integer>('unrepresentableChars'));
    Assert.AreEqual('Windows-1252', LResultObj.GetValue<string>('encoding'));
  finally
    LJson.Free;
  end;
  Assert.IsFalse(TFile.Exists(LPath));
end;

procedure TBatchWriteTests.BatchWrite_DryRun_ReportsWithoutWriting;
var
  LPath: string;
  LFiles: TJSONArray;
  LEntry, LJson, LResultObj: TJSONObject;
begin
  LPath := MakeTempPath('dry.txt');
  LFiles := TJSONArray.Create;
  LEntry := MakeFileEntry(LPath, 'dry');
  LEntry.AddPair('dryRun', TJSONBool.Create(True));
  LFiles.AddElement(LEntry);
  LJson := ExecuteBatchWrite(FCacheManager, LFiles);
  LFiles.Free;
  try
    LResultObj := LJson.GetValue<TJSONArray>('results').Items[0] as TJSONObject;
    Assert.IsTrue(LResultObj.GetValue<Boolean>('dryRun'));
    Assert.AreEqual('UTF-8', LResultObj.GetValue<string>('encoding'));
  finally
    LJson.Free;
  end;
  Assert.IsFalse(TFile.Exists(LPath));
end;

// Runs ValidateArguments against the batch tool's real schema.
procedure ValidateBatchArgs(ACacheManager: TCacheManager; const AJson: string);
var
  LTool: IMcpTool;
  LSchema, LArgs: TJSONObject;
begin
  LTool := TBatchWriteTool.Create(ACacheManager);
  LSchema := LTool.BuildInputSchema;
  try
    LArgs := TJSONObject.ParseJSONValue(AJson) as TJSONObject;
    try
      ValidateArguments(LSchema, LArgs);
    finally
      LArgs.Free;
    end;
  finally
    LSchema.Free;
  end;
end;

procedure TBatchWriteTests.ValidateArguments_RejectsUnknownName;
begin
  Assert.WillRaise(
    procedure
    begin
      ValidateBatchArgs(FCacheManager,
        '{"files":[{"path":"a","content":"b"}],"bom":true}');
    end,
    EInvalidArgumentError);
end;

procedure TBatchWriteTests.ValidateArguments_RejectsWrongType;
begin
  Assert.WillRaise(
    procedure
    begin
      ValidateBatchArgs(FCacheManager,
        '{"files":[{"path":"a","content":"b","hasBom":"true"}]}');
    end,
    EInvalidArgumentError);
end;

procedure TBatchWriteTests.ValidateArguments_RejectsUnknownNestedName;
begin
  Assert.WillRaise(
    procedure
    begin
      ValidateBatchArgs(FCacheManager,
        '{"files":[{"path":"a","content":"b","bom":true}]}');
    end,
    EInvalidArgumentError);
end;

procedure TBatchWriteTests.ValidateArguments_AcceptsValidArguments;
begin
  Assert.WillNotRaise(
    procedure
    begin
      ValidateBatchArgs(FCacheManager,
        '{"files":[{"path":"a","content":"b","hasBom":true,' +
        '"encoding":"UTF-8","lineEnding":"LF","dryRun":false}]}');
    end);
end;

procedure TBatchWriteTests.ValidateArguments_TreatsNullAsAbsent;
begin
  // Clients commonly send null for omitted optional values
  Assert.WillNotRaise(
    procedure
    begin
      ValidateBatchArgs(FCacheManager,
        '{"files":[{"path":"a","content":"b","encoding":null,"hasBom":null}]}');
    end);
end;

procedure TBatchWriteTests.Execute_MissingFiles_RaisesInvalidArgument;
var
  LTool: IMcpTool;
begin
  LTool := TBatchWriteTool.Create(FCacheManager);
  Assert.WillRaise(
    procedure
    begin
      LTool.Execute(nil).Free;
    end, EInvalidArgumentError);
end;

procedure TBatchWriteTests.Execute_EmptyFiles_RaisesInvalidArgument;
var
  LTool: IMcpTool;
  LArgs: TJSONObject;
begin
  LTool := TBatchWriteTool.Create(FCacheManager);
  LArgs := TJSONObject.ParseJSONValue('{"files":[]}') as TJSONObject;
  try
    Assert.WillRaise(
      procedure
      begin
        LTool.Execute(LArgs).Free;
      end, EInvalidArgumentError);
  finally
    LArgs.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TBatchWriteTests);

end.
