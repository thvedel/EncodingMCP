unit Tests.Tools.ListFiles;

/// <summary>
///   Tests for the list_files MCP tool.
/// </summary>

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  Encoding.CacheManager;

type
  [TestFixture]
  TListFilesTests = class
  strict private
    FTempDir: string;
    FCacheManager: TCacheManager;
  public
    [Setup]
    procedure Setup;
    [Teardown]
    procedure Teardown;

    [Test]
    procedure ListFiles_ReturnsAllFiles;
    [Test]
    procedure ListFiles_PatternFilters;
    [Test]
    procedure ListFiles_EmptyDirectory;
    [Test]
    procedure ListFiles_SubdirectoryIncluded;
    [Test]
    procedure ListFiles_NonExistentDir_Raises;
  end;

implementation

uses
  System.IOUtils,
  System.JSON,
  System.Generics.Collections,
  MCP.Tools,
  Tools.ListFiles;

{ TListFilesTests }

procedure TListFilesTests.Setup;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'ListFilesTest_' +
    FormatDateTime('yyyymmdd_hhnnsszzz', Now));
  TDirectory.CreateDirectory(FTempDir);
  FCacheManager := TCacheManager.Create;
end;

procedure TListFilesTests.Teardown;
begin
  FCacheManager.Free;
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

function ExecuteListFiles(ACacheManager: TCacheManager;
  const APath: string; const APattern: string = ''): TJSONObject;
var
  LTool: TListFilesTool;
  LArgs: TJSONObject;
  LResult: TJSONObject;
  LContent: TJSONArray;
  LText: string;
begin
  LTool := TListFilesTool.Create(ACacheManager);
  try
    LArgs := TJSONObject.Create;
    try
      LArgs.AddPair('path', APath);
      if APattern <> '' then
        LArgs.AddPair('pattern', APattern);
      LResult := LTool.Execute(LArgs);
      try
        // Parse the inner JSON from content[0].text
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
    // TListFilesTool is ref-counted via TInterfacedObject
  end;
end;

procedure TListFilesTests.ListFiles_ReturnsAllFiles;
var
  LJson: TJSONObject;
  LFiles: TJSONArray;
begin
  TFile.WriteAllText(TPath.Combine(FTempDir, 'a.txt'), 'a');
  TFile.WriteAllText(TPath.Combine(FTempDir, 'b.pas'), 'b');
  TFile.WriteAllText(TPath.Combine(FTempDir, 'c.dfm'), 'c');
  LJson := ExecuteListFiles(FCacheManager, FTempDir);
  try
    Assert.AreEqual(3, LJson.GetValue<Integer>('totalFiles'));
    LFiles := LJson.GetValue<TJSONArray>('files');
    Assert.AreEqual(3, LFiles.Count);
  finally
    LJson.Free;
  end;
end;

procedure TListFilesTests.ListFiles_PatternFilters;
var
  LJson: TJSONObject;
  LFiles: TJSONArray;
begin
  TFile.WriteAllText(TPath.Combine(FTempDir, 'a.txt'), 'a');
  TFile.WriteAllText(TPath.Combine(FTempDir, 'b.pas'), 'b');
  TFile.WriteAllText(TPath.Combine(FTempDir, 'c.pas'), 'c');
  LJson := ExecuteListFiles(FCacheManager, FTempDir, '*.pas');
  try
    Assert.AreEqual(2, LJson.GetValue<Integer>('totalFiles'));
    LFiles := LJson.GetValue<TJSONArray>('files');
    Assert.AreEqual(2, LFiles.Count);
  finally
    LJson.Free;
  end;
end;

procedure TListFilesTests.ListFiles_EmptyDirectory;
var
  LJson: TJSONObject;
begin
  LJson := ExecuteListFiles(FCacheManager, FTempDir);
  try
    Assert.AreEqual(0, LJson.GetValue<Integer>('totalFiles'));
  finally
    LJson.Free;
  end;
end;

procedure TListFilesTests.ListFiles_SubdirectoryIncluded;
var
  LSubDir: string;
  LJson: TJSONObject;
  LFiles: TJSONArray;
  I: Integer;
  LHasSub: Boolean;
begin
  TFile.WriteAllText(TPath.Combine(FTempDir, 'root.txt'), 'r');
  LSubDir := TPath.Combine(FTempDir, 'sub');
  TDirectory.CreateDirectory(LSubDir);
  TFile.WriteAllText(TPath.Combine(LSubDir, 'child.txt'), 'c');
  LJson := ExecuteListFiles(FCacheManager, FTempDir);
  try
    Assert.AreEqual(2, LJson.GetValue<Integer>('totalFiles'));
    LFiles := LJson.GetValue<TJSONArray>('files');
    LHasSub := False;
    for I := 0 to LFiles.Count - 1 do
      if LFiles.Items[I].Value.Contains('sub/') then
        LHasSub := True;
    Assert.IsTrue(LHasSub, 'Should include files in subdirectory with relative path');
  finally
    LJson.Free;
  end;
end;

procedure TListFilesTests.ListFiles_NonExistentDir_Raises;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    ExecuteListFiles(FCacheManager, TPath.Combine(FTempDir, 'nonexistent')).Free;
  except
    LRaised := True;
  end;
  Assert.IsTrue(LRaised, 'Should raise for non-existent directory');
end;

initialization
  TDUnitX.RegisterTestFixture(TListFilesTests);

end.
