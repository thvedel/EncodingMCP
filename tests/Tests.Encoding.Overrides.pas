unit Tests.Encoding.Overrides;

/// <summary>
///   Tests for pattern overrides, the sidecar chain (nearest to outermost),
///   deterministic reloading of changed sidecars and the set_encoding_override
///   tool.
/// </summary>

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.JSON,
  Encoding.CacheManager;

type
  [TestFixture]
  TOverrideTests = class
  strict private
    FTempDir: string;
    FCacheManager: TCacheManager;
    function MakeTempPath(const ARelative: string): string;
    procedure WriteAscii(const ARelative, AText: string);
    procedure WriteSidecar(const ARelativeDir, AOverridesJson: string);
    function ExecuteTool(AArgs: TJSONObject): TJSONObject;
  public
    [Setup]
    procedure Setup;
    [Teardown]
    procedure Teardown;

    [Test]
    procedure NormalizePattern_AcceptsSupportedForms;
    [Test]
    procedure NormalizePattern_RejectsUnsupportedSyntax;
    [Test]
    procedure PathPattern_MatchesOnlyBelowFolder;
    [Test]
    procedure DoubleStar_MiddleMatchesZeroSegments_TrailingNeedsOne;
    [Test]
    procedure SingleStar_DoesNotCrossFolders;
    [Test]
    procedure MostSpecificPattern_Wins;
    [Test]
    procedure OuterOverride_AppliesInSubfolderWithOwnDproj;
    [Test]
    procedure ExistingSubSidecar_InheritsOuterOverride;
    [Test]
    procedure NearerSidecarPattern_Wins;
    [Test]
    procedure OverrideRemovedOnDisk_IsNotResurrectedOnSave;
    [Test]
    procedure OverrideAddedOnDisk_TakesEffectImmediately;
    [Test]
    procedure OverrideRemovedByOtherInstance_IsNotResurrected;
    [Test]
    procedure SidecarFile_IsNotCachedItself;
    [Test]
    procedure Tool_SetPattern_ReportsSidecarAndScope;
    [Test]
    procedure Tool_PathPattern_AppliesBelowNestedProject;
    [Test]
    procedure Tool_InvalidPattern_Raises;
    [Test]
    procedure Tool_RemovePattern_RemovesAndReports;
    [Test]
    procedure Tool_RemovePathOverride_RemovesEntry;
    [Test]
    procedure Tool_RemoveWithEncoding_Raises;
    [Test]
    procedure Tool_RemovePattern_FromNestedDirectory_ClearsWholeChain;
    [Test]
    procedure Tool_SetPattern_WarnsAboutConflictingNearerSidecar;
  end;

implementation

uses
  System.IOUtils,
  System.Generics.Collections,
  Encoding.Types,
  Encoding.Workspace,
  Encoding.Cache,
  FileIO.Reader,
  MCP.Tools,
  Tools.SetOverride;

{ TOverrideTests }

procedure TOverrideTests.Setup;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'OverrideTests_' +
    FormatDateTime('yyyymmddhhnnsszzz', Now));
  TDirectory.CreateDirectory(FTempDir);
  TDirectory.CreateDirectory(TPath.Combine(FTempDir, '.git'));
  SetWorkspaceRoots([FTempDir]);
  FCacheManager := TCacheManager.Create;
end;

procedure TOverrideTests.Teardown;
begin
  FreeAndNil(FCacheManager);
  SetWorkspaceRoots([]);
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

function TOverrideTests.MakeTempPath(const ARelative: string): string;
begin
  Result := TPath.Combine(FTempDir, ARelative.Replace('/', PathDelim));
end;

procedure TOverrideTests.WriteAscii(const ARelative, AText: string);
var
  LPath: string;
begin
  LPath := MakeTempPath(ARelative);
  TDirectory.CreateDirectory(TPath.GetDirectoryName(LPath));
  TFile.WriteAllBytes(LPath, TEncoding.ASCII.GetBytes(AText));
end;

procedure TOverrideTests.WriteSidecar(const ARelativeDir, AOverridesJson: string);
var
  LDir: string;
begin
  LDir := MakeTempPath(ARelativeDir);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, CACHE_FILE_NAME),
    '{"version":1,"files":{},"overrides":' + AOverridesJson + '}', TEncoding.UTF8);
end;

function TOverrideTests.ExecuteTool(AArgs: TJSONObject): TJSONObject;
var
  LTool: IMcpTool;
  LResult: TJSONObject;
  LText: string;
begin
  LTool := TSetOverrideTool.Create(FCacheManager);
  try
    LResult := LTool.Execute(AArgs);
    try
      LText := LResult.GetValue<TJSONArray>('content').Items[0].GetValue<string>('text');
      Result := TJSONObject.ParseJSONValue(LText) as TJSONObject;
    finally
      LResult.Free;
    end;
  finally
    AArgs.Free;
  end;
end;

procedure TOverrideTests.NormalizePattern_AcceptsSupportedForms;
begin
  Assert.AreEqual('*.pas', TEncodingCache.NormalizePattern('*.PAS'));
  Assert.AreEqual('*.pas', TEncodingCache.NormalizePattern('.pas'));
  Assert.AreEqual('*.pas', TEncodingCache.NormalizePattern('pas'));
  Assert.AreEqual('*.pas', TEncodingCache.NormalizePattern('**/*.pas'));
  Assert.AreEqual('src/*.pas', TEncodingCache.NormalizePattern('Src\*.pas'));
  Assert.AreEqual('src/**/*.dfm', TEncodingCache.NormalizePattern('./src/**/*.dfm'));
  Assert.AreEqual('xmo/**/*.pas', TEncodingCache.NormalizePattern('XMO/**/*.pas'));
end;

procedure TOverrideTests.NormalizePattern_RejectsUnsupportedSyntax;
const
  INVALID: array[0..8] of string = ('', '/abs/*.pas', 'C:/x/*.pas', 'src/[ab].pas',
    '{a,b}.pas', '!*.pas', 'src/../*.pas', 'src//x.pas', 'src/a**/x.pas');
var
  LPattern: string;
begin
  for LPattern in INVALID do
    Assert.WillRaise(
      procedure
      begin
        TEncodingCache.NormalizePattern(LPattern);
      end, EInvalidOverridePattern, 'Pattern should be rejected: "' + LPattern + '"');
end;

procedure TOverrideTests.PathPattern_MatchesOnlyBelowFolder;
var
  LCache: TEncodingCache;
  LId: TEncodingId;
begin
  LCache := FCacheManager.ResolveOutermost(FTempDir);
  LCache.SetPatternOverride('src/**/*.pas', TEncodingId.Windows1252);
  Assert.IsTrue(LCache.TryGetPatternOverride('src/a/b/U.pas', LId));
  Assert.AreEqual(TEncodingId.Windows1252, LId);
  Assert.IsTrue(LCache.TryGetPatternOverride('SRC/U.PAS', LId), 'Matching is case-insensitive');
  Assert.IsFalse(LCache.TryGetPatternOverride('other/U.pas', LId));
  Assert.IsFalse(LCache.TryGetPatternOverride('src/U.dfm', LId));
end;

procedure TOverrideTests.DoubleStar_MiddleMatchesZeroSegments_TrailingNeedsOne;
var
  LCache: TEncodingCache;
  LId: TEncodingId;
begin
  LCache := FCacheManager.ResolveOutermost(FTempDir);
  LCache.SetPatternOverride('src/**/*.pas', TEncodingId.Windows1252);
  Assert.IsTrue(LCache.TryGetPatternOverride('src/U.pas', LId), 'middle ** spans zero segments');
  LCache.SetPatternOverride('lib/**', TEncodingId.Iso88591);
  Assert.IsTrue(LCache.TryGetPatternOverride('lib/a.txt', LId));
  Assert.IsTrue(LCache.TryGetPatternOverride('lib/x/y/a.txt', LId));
  Assert.IsFalse(LCache.TryGetPatternOverride('lib', LId), 'trailing ** must not match the folder itself');
end;

procedure TOverrideTests.SingleStar_DoesNotCrossFolders;
var
  LCache: TEncodingCache;
  LId: TEncodingId;
begin
  LCache := FCacheManager.ResolveOutermost(FTempDir);
  LCache.SetPatternOverride('src/*.pas', TEncodingId.Windows1252);
  Assert.IsTrue(LCache.TryGetPatternOverride('src/U.pas', LId));
  Assert.IsFalse(LCache.TryGetPatternOverride('src/sub/U.pas', LId));
end;

procedure TOverrideTests.MostSpecificPattern_Wins;
var
  LCache: TEncodingCache;
  LId: TEncodingId;
begin
  LCache := FCacheManager.ResolveOutermost(FTempDir);
  LCache.SetPatternOverride('*.pas', TEncodingId.Utf8);
  LCache.SetPatternOverride('src/**/*.pas', TEncodingId.Windows1252);
  Assert.IsTrue(LCache.TryGetPatternOverride('src/U.pas', LId));
  Assert.AreEqual(TEncodingId.Windows1252, LId, 'A path pattern beats a file-name pattern');
  Assert.IsTrue(LCache.TryGetPatternOverride('U.pas', LId));
  Assert.AreEqual(TEncodingId.Utf8, LId);
end;

procedure TOverrideTests.OuterOverride_AppliesInSubfolderWithOwnDproj;
var
  LResult: TReadResult;
begin
  // Regression (bug 4): a *.pas override in the repository root did not apply
  // in subfolders with their own .dproj, and reading created new sidecars there.
  WriteSidecar('', '{"*.pas":"Windows-1252"}');
  WriteAscii('sub/Demo.dproj', '<Project/>');
  WriteAscii('sub/DemoForm.pas', 'unit DemoForm;');

  LResult := ReadTextFile(MakeTempPath('sub/DemoForm.pas'), FCacheManager);
  FCacheManager.FlushAll;

  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId);
  Assert.AreEqual(TEncodingSource.PatternOverride, LResult.Source);
  Assert.IsFalse(TFile.Exists(MakeTempPath('sub/' + CACHE_FILE_NAME)),
    'No new sidecar may be created in a subfolder');
  Assert.Contains(TFile.ReadAllText(MakeTempPath(CACHE_FILE_NAME)), 'sub/DemoForm.pas');
end;

procedure TOverrideTests.ExistingSubSidecar_InheritsOuterOverride;
var
  LResult: TReadResult;
begin
  WriteSidecar('', '{"*.pas":"Windows-1252"}');
  WriteSidecar('sub', '{}');
  WriteAscii('sub/U.pas', 'unit U;');

  LResult := ReadTextFile(MakeTempPath('sub/U.pas'), FCacheManager);
  FCacheManager.FlushAll;

  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId);
  Assert.Contains(TFile.ReadAllText(MakeTempPath('sub/' + CACHE_FILE_NAME)), 'U.pas',
    'The file entry belongs to the nearest existing sidecar');
end;

procedure TOverrideTests.NearerSidecarPattern_Wins;
var
  LResult: TReadResult;
begin
  WriteSidecar('', '{"*.pas":"Windows-1252"}');
  WriteSidecar('sub', '{"*.pas":"ISO-8859-1"}');
  WriteAscii('sub/U.pas', 'unit U;');
  WriteAscii('V.pas', 'unit V;');

  LResult := ReadTextFile(MakeTempPath('sub/U.pas'), FCacheManager);
  Assert.AreEqual(TEncodingId.Iso88591, LResult.EncodingId);
  LResult := ReadTextFile(MakeTempPath('V.pas'), FCacheManager);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId);
end;

procedure TOverrideTests.OverrideRemovedOnDisk_IsNotResurrectedOnSave;
var
  LJson: TJSONObject;
  LCache: TEncodingCache;
  LRelative: string;
  LId: TEncodingId;
begin
  // Regression (bug 5): overrides removed by hand came back on the next save.
  WriteSidecar('', '{"*.pas":"Windows-1252"}');
  WriteAscii('A.pas', 'unit A;');
  Assert.AreEqual(TEncodingId.Windows1252,
    ReadTextFile(MakeTempPath('A.pas'), FCacheManager).EncodingId);

  WriteSidecar('', '{}');
  WriteAscii('B.pas', 'unit B;');
  ReadTextFile(MakeTempPath('B.pas'), FCacheManager);
  FCacheManager.FlushAll;

  LJson := TJSONObject.ParseJSONValue(TFile.ReadAllText(MakeTempPath(CACHE_FILE_NAME))) as TJSONObject;
  try
    Assert.AreEqual(0, LJson.GetValue<TJSONObject>('overrides').Count);
  finally
    LJson.Free;
  end;
  FCacheManager.Resolve(MakeTempPath('A.pas'), LCache, LRelative);
  Assert.IsFalse(LCache.TryGetPatternOverride(LRelative, LId));
end;

procedure TOverrideTests.OverrideAddedOnDisk_TakesEffectImmediately;
var
  LResult: TReadResult;
begin
  WriteAscii('A.pas', 'unit A;');
  Assert.AreEqual(TEncodingId.Ascii, ReadTextFile(MakeTempPath('A.pas'), FCacheManager).EncodingId);
  FCacheManager.FlushAll;

  // Edited by hand while the server is running
  WriteSidecar('', '{"*.pas":"Windows-1252"}');

  LResult := ReadTextFile(MakeTempPath('A.pas'), FCacheManager);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId);
  Assert.AreEqual(TEncodingSource.PatternOverride, LResult.Source);
end;

procedure TOverrideTests.OverrideRemovedByOtherInstance_IsNotResurrected;
var
  LOther: TCacheManager;
begin
  WriteSidecar('', '{"*.pas":"Windows-1252"}');
  WriteAscii('A.pas', 'unit A;');
  ReadTextFile(MakeTempPath('A.pas'), FCacheManager);

  LOther := TCacheManager.Create;
  try
    Assert.IsTrue(LOther.ResolveOutermost(FTempDir).RemovePatternOverride('*.pas'));
    LOther.FlushAll;
  finally
    LOther.Free;
  end;

  WriteAscii('B.pas', 'unit B;');
  ReadTextFile(MakeTempPath('B.pas'), FCacheManager);
  FCacheManager.FlushAll;
  Assert.DoesNotContain(TFile.ReadAllText(MakeTempPath(CACHE_FILE_NAME)), '*.pas');
end;

procedure TOverrideTests.SidecarFile_IsNotCachedItself;
var
  LSidecar, LBefore: string;
begin
  WriteSidecar('', '{"*.pas":"Windows-1252"}');
  LSidecar := MakeTempPath(CACHE_FILE_NAME);
  LBefore := TFile.ReadAllText(LSidecar);
  ReadTextFile(LSidecar, FCacheManager);
  FCacheManager.FlushAll;
  Assert.AreEqual(LBefore, TFile.ReadAllText(LSidecar),
    'Reading the sidecar must not make the server rewrite it');
end;

procedure TOverrideTests.Tool_SetPattern_ReportsSidecarAndScope;
var
  LArgs, LJson: TJSONObject;
begin
  LArgs := TJSONObject.Create;
  LArgs.AddPair('pattern', '*.dfm');
  LArgs.AddPair('encoding', 'Windows-1252');
  LJson := ExecuteTool(LArgs);
  try
    Assert.AreEqual('set', LJson.GetValue<string>('action'));
    Assert.AreEqual('pattern', LJson.GetValue<string>('scope'));
    Assert.AreEqual('*.dfm', LJson.GetValue<string>('pattern'));
    Assert.AreEqual(MakeTempPath(CACHE_FILE_NAME), LJson.GetValue<string>('sidecar'));
    Assert.AreEqual('file name', LJson.GetValue<string>('matches'));
  finally
    LJson.Free;
  end;
  Assert.Contains(TFile.ReadAllText(MakeTempPath(CACHE_FILE_NAME)), '*.dfm');
end;

procedure TOverrideTests.Tool_PathPattern_AppliesBelowNestedProject;
var
  LArgs, LJson: TJSONObject;
  LResult: TReadResult;
begin
  // Regression (bug 3): path patterns were accepted but never matched.
  LArgs := TJSONObject.Create;
  LArgs.AddPair('pattern', 'XMO/**/*.pas');
  LArgs.AddPair('encoding', 'Windows-1252');
  LJson := ExecuteTool(LArgs);
  try
    Assert.AreEqual('path relative to ' + FTempDir, LJson.GetValue<string>('matches'));
  finally
    LJson.Free;
  end;
  WriteAscii('XMO/booking/common/Common.dproj', '<Project/>');
  WriteAscii('XMO/booking/common/U.pas', 'unit U;');
  WriteAscii('Tools/U.pas', 'unit U;');

  LResult := ReadTextFile(MakeTempPath('XMO/booking/common/U.pas'), FCacheManager);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId);
  LResult := ReadTextFile(MakeTempPath('Tools/U.pas'), FCacheManager);
  Assert.AreEqual(TEncodingId.Ascii, LResult.EncodingId);
end;

procedure TOverrideTests.Tool_InvalidPattern_Raises;
begin
  Assert.WillRaise(
    procedure
    var
      LArgs: TJSONObject;
    begin
      LArgs := TJSONObject.Create;
      LArgs.AddPair('pattern', 'src/{a,b}.pas');
      LArgs.AddPair('encoding', 'Windows-1252');
      ExecuteTool(LArgs).Free;
    end, EInvalidOverridePattern);
end;

procedure TOverrideTests.Tool_RemovePattern_RemovesAndReports;
var
  LArgs, LJson: TJSONObject;
  LResult: TReadResult;
begin
  LArgs := TJSONObject.Create;
  LArgs.AddPair('pattern', '*.pas');
  LArgs.AddPair('encoding', 'Windows-1252');
  ExecuteTool(LArgs).Free;

  LArgs := TJSONObject.Create;
  LArgs.AddPair('pattern', '.pas');
  LArgs.AddPair('remove', TJSONBool.Create(True));
  LJson := ExecuteTool(LArgs);
  try
    Assert.AreEqual('removed', LJson.GetValue<string>('action'));
    Assert.AreEqual(MakeTempPath(CACHE_FILE_NAME),
      LJson.GetValue<TJSONArray>('removedFrom').Items[0].Value);
  finally
    LJson.Free;
  end;

  WriteAscii('A.pas', 'unit A;');
  LResult := ReadTextFile(MakeTempPath('A.pas'), FCacheManager);
  Assert.AreEqual(TEncodingSource.Detected, LResult.Source);

  Assert.WillRaise(
    procedure
    var
      LRemoveArgs: TJSONObject;
    begin
      LRemoveArgs := TJSONObject.Create;
      LRemoveArgs.AddPair('pattern', '*.pas');
      LRemoveArgs.AddPair('remove', TJSONBool.Create(True));
      ExecuteTool(LRemoveArgs).Free;
    end, EOverrideNotFound);
end;

procedure TOverrideTests.Tool_RemovePathOverride_RemovesEntry;
var
  LArgs, LJson: TJSONObject;
  LCache: TEncodingCache;
  LRelative: string;
  LEntry: TCacheEntry;
begin
  WriteAscii('A.pas', 'unit A;');
  LArgs := TJSONObject.Create;
  LArgs.AddPair('path', MakeTempPath('A.pas'));
  LArgs.AddPair('encoding', 'Windows-1252');
  ExecuteTool(LArgs).Free;

  LArgs := TJSONObject.Create;
  LArgs.AddPair('path', MakeTempPath('A.pas'));
  LArgs.AddPair('remove', TJSONBool.Create(True));
  LJson := ExecuteTool(LArgs);
  try
    Assert.AreEqual('removed', LJson.GetValue<string>('action'));
    Assert.AreEqual('file', LJson.GetValue<string>('scope'));
  finally
    LJson.Free;
  end;

  FCacheManager.Resolve(MakeTempPath('A.pas'), LCache, LRelative);
  Assert.IsFalse(LCache.TryGet(LRelative, LEntry));
  Assert.WillRaise(
    procedure
    var
      LRemoveArgs: TJSONObject;
    begin
      LRemoveArgs := TJSONObject.Create;
      LRemoveArgs.AddPair('path', MakeTempPath('A.pas'));
      LRemoveArgs.AddPair('remove', TJSONBool.Create(True));
      ExecuteTool(LRemoveArgs).Free;
    end, EOverrideNotFound);
end;

procedure TOverrideTests.Tool_RemoveWithEncoding_Raises;
begin
  Assert.WillRaise(
    procedure
    var
      LArgs: TJSONObject;
    begin
      LArgs := TJSONObject.Create;
      LArgs.AddPair('pattern', '*.pas');
      LArgs.AddPair('encoding', 'Windows-1252');
      LArgs.AddPair('remove', TJSONBool.Create(True));
      ExecuteTool(LArgs).Free;
    end, EArgumentException);
end;

procedure TOverrideTests.Tool_RemovePattern_FromNestedDirectory_ClearsWholeChain;
var
  LArgs, LJson: TJSONObject;
  LRemovedFrom: TJSONArray;
  LResult: TReadResult;
begin
  // The same pattern in both the nearer and the outer sidecar: removing from
  // the nested directory must clear both, so the file is detected afterwards.
  WriteSidecar('', '{"*.pas":"Windows-1252"}');
  WriteSidecar('sub', '{"*.pas":"ISO-8859-1"}');
  WriteAscii('sub/U.pas', 'unit U;');

  LArgs := TJSONObject.Create;
  LArgs.AddPair('pattern', '*.pas');
  LArgs.AddPair('directory', MakeTempPath('sub'));
  LArgs.AddPair('remove', TJSONBool.Create(True));
  LJson := ExecuteTool(LArgs);
  try
    LRemovedFrom := LJson.GetValue<TJSONArray>('removedFrom');
    Assert.AreEqual(2, LRemovedFrom.Count);
    Assert.AreEqual(MakeTempPath('sub\' + CACHE_FILE_NAME), LRemovedFrom.Items[0].Value);
    Assert.AreEqual(MakeTempPath(CACHE_FILE_NAME), LRemovedFrom.Items[1].Value);
  finally
    LJson.Free;
  end;

  LResult := ReadTextFile(MakeTempPath('sub/U.pas'), FCacheManager);
  Assert.AreEqual(TEncodingSource.Detected, LResult.Source);
  Assert.DoesNotContain(TFile.ReadAllText(MakeTempPath(CACHE_FILE_NAME)), '*.pas');
  Assert.DoesNotContain(TFile.ReadAllText(MakeTempPath('sub\' + CACHE_FILE_NAME)), '*.pas');
end;

procedure TOverrideTests.Tool_SetPattern_WarnsAboutConflictingNearerSidecar;
var
  LArgs, LJson: TJSONObject;
  LWarnings: TJSONArray;
begin
  WriteSidecar('sub', '{"*.pas":"ISO-8859-1"}');
  WriteAscii('sub/U.pas', 'unit U;');

  LArgs := TJSONObject.Create;
  LArgs.AddPair('pattern', '*.pas');
  LArgs.AddPair('encoding', 'Windows-1252');
  LArgs.AddPair('directory', MakeTempPath('sub'));
  LJson := ExecuteTool(LArgs);
  try
    Assert.AreEqual(MakeTempPath(CACHE_FILE_NAME), LJson.GetValue<string>('sidecar'),
      'set always targets the outermost sidecar');
    LWarnings := LJson.GetValue<TJSONArray>('warnings');
    Assert.IsNotNull(LWarnings, 'a conflicting nearer sidecar must be reported');
    Assert.Contains(LWarnings.Items[0].Value, 'ISO-8859-1');
  finally
    LJson.Free;
  end;
  Assert.AreEqual(TEncodingId.Iso88591,
    ReadTextFile(MakeTempPath('sub/U.pas'), FCacheManager).EncodingId);
end;

initialization
  TDUnitX.RegisterTestFixture(TOverrideTests);

end.
