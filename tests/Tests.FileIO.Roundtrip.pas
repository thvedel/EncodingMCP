unit Tests.FileIO.Roundtrip;

/// <summary>
///   End-to-end tests of read/write round-trip via FileIO units.
///   Verifies that a Windows-1252 file preserves its encoding through
///   a read → modify → write cycle.
/// </summary>

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  Encoding.CacheManager;

type
  [TestFixture]
  TRoundtripTests = class
  strict private
    FTempDir: string;
    FCacheManager: TCacheManager;
    function MakeTempPath(const AFileName: string): string;
    procedure WriteBytes(const APath: string; const ABytes: TBytes);
    function ReadBytes(const APath: string): TBytes;
    function IndexOfByte(const ABytes: TBytes; AByte: Byte): Integer;
  public
    [Setup]
    procedure Setup;
    [Teardown]
    procedure Teardown;
    [Test]
    procedure ReadWindows1252File_DanishChars;
    [Test]
    procedure ReadWindows1252File_PreservesEuro;
    [Test]
    procedure WriteRoundtrip_PreservesWindows1252Bytes;
    [Test]
    procedure WriteUtf8WithBom_ProducesBom;
    [Test]
    procedure WriteToNewFile_DefaultsToUtf8WithBom;
    [Test]
    procedure FlushAll_WritesSidecarCache;
    [Test]
    procedure AtomicWrite_NoTempFileLeft;
    [Test]
    procedure CacheMerge_PreservesEntriesFromDisk;
    [Test]
    procedure AsciiFile_NonAsciiContent_UpgradesToWindows1252;
    [Test]
    procedure AsciiFile_NeverRead_NonAsciiContent_UpgradesToWindows1252;
    [Test]
    procedure ExplicitAscii_NonAsciiContent_RaisesAndKeepsFile;
    [Test]
    procedure Windows1252_UnrepresentableChar_Raises;
    [Test]
    procedure Windows1252_UnrepresentableEmoji_CountsOnceAndSamplesWholeChar;
    [Test]
    procedure AsciiFile_HasBomTrue_WritesUtf8WithBom;
    [Test]
    procedure PatternOverride_NeverReadFile_UsesOverride;
    [Test]
    procedure ExternalEncodingChange_AfterCache_IsHonoured;
    [Test]
    procedure ExplicitEncoding_PreservesLineEndingAndBom;
    [Test]
    procedure ExplicitUnicodeEncoding_FromAnsi_AddsBomKeepsLf;
    [Test]
    procedure DryRun_DoesNotWrite;
    [Test]
    procedure Sidecar_UsesNewName;
    [Test]
    procedure LegacySidecar_IsReadAndMigratedOnSave;
    [Test]
    procedure BothSidecars_NewWinsAndLegacyIsKept;
    [Test]
    procedure LegacySidecar_DeleteFails_MigrationStillSucceeds;
  end;

implementation

uses
  System.IOUtils,
  System.Classes,
  Encoding.Types,
  Encoding.Cache,
  FileIO.Reader,
  FileIO.Writer;

{ TRoundtripTests }

function TRoundtripTests.MakeTempPath(const AFileName: string): string;
begin
  Result := TPath.Combine(FTempDir, AFileName);
end;

procedure TRoundtripTests.WriteBytes(const APath: string; const ABytes: TBytes);
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then
      LStream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    LStream.Free;
  end;
end;

function TRoundtripTests.ReadBytes(const APath: string): TBytes;
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(APath, fmOpenRead);
  try
    SetLength(Result, LStream.Size);
    if LStream.Size > 0 then
      LStream.ReadBuffer(Result[0], LStream.Size);
  finally
    LStream.Free;
  end;
end;

procedure TRoundtripTests.Setup;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'EncodingMCPTests_' +
    FormatDateTime('yyyymmddhhnnsszzz', Now));
  TDirectory.CreateDirectory(FTempDir);
  // Marker so workspace detection finds this directory as root
  TDirectory.CreateDirectory(TPath.Combine(FTempDir, '.git'));
  FCacheManager := TCacheManager.Create;
end;

procedure TRoundtripTests.Teardown;
begin
  FreeAndNil(FCacheManager);
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

procedure TRoundtripTests.ReadWindows1252File_DanishChars;
var
  LPath: string;
  LResult: TReadResult;
begin
  LPath := MakeTempPath('Test.pas');
  // 'Hej æøå' in Windows-1252
  WriteBytes(LPath, TBytes.Create($48, $65, $6A, $20, $E6, $F8, $E5));
  LResult := ReadTextFile(LPath, FCacheManager);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId);
  Assert.AreEqual('Hej '#$00E6#$00F8#$00E5, LResult.Content);
end;

procedure TRoundtripTests.ReadWindows1252File_PreservesEuro;
var
  LPath: string;
  LResult: TReadResult;
begin
  LPath := MakeTempPath('Euro.pas');
  // '€' in Windows-1252 is 0x80
  WriteBytes(LPath, TBytes.Create($80, $20, $31, $30, $30));
  LResult := ReadTextFile(LPath, FCacheManager);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId);
  Assert.AreEqual(#$20AC' 100', LResult.Content);
end;

procedure TRoundtripTests.WriteRoundtrip_PreservesWindows1252Bytes;
var
  LPath: string;
  LBytesAfter: TBytes;
  LOptions: TWriteOptions;
begin
  LPath := MakeTempPath('Roundtrip.pas');
  // Write original Windows-1252 file
  WriteBytes(LPath, TBytes.Create($48, $65, $6A, $20, $E6, $F8, $E5));
  // Read it (caches encoding)
  ReadTextFile(LPath, FCacheManager);
  // Write new content with same characters
  LOptions := MakeDefaultWriteOptions;
  WriteTextFile(LPath, 'Hej '#$00E6#$00F8#$00E5, FCacheManager, LOptions);
  // Verify that output is Windows-1252 bytes (E6 F8 E5)
  LBytesAfter := ReadBytes(LPath);
  Assert.AreEqual($E6, LBytesAfter[4]);
  Assert.AreEqual($F8, LBytesAfter[5]);
  Assert.AreEqual($E5, LBytesAfter[6]);
end;

procedure TRoundtripTests.WriteUtf8WithBom_ProducesBom;
var
  LPath: string;
  LBytes: TBytes;
  LOptions: TWriteOptions;
begin
  LPath := MakeTempPath('Bom.txt');
  LOptions := MakeDefaultWriteOptions;
  LOptions.EncodingOverride := TEncodingId.Utf8;
  LOptions.HasBomOverride := 1;
  WriteTextFile(LPath, 'Hello', FCacheManager, LOptions);
  LBytes := ReadBytes(LPath);
  Assert.IsTrue(Length(LBytes) >= 3);
  Assert.AreEqual($EF, LBytes[0]);
  Assert.AreEqual($BB, LBytes[1]);
  Assert.AreEqual($BF, LBytes[2]);
end;

procedure TRoundtripTests.WriteToNewFile_DefaultsToUtf8WithBom;
var
  LPath: string;
  LBytes: TBytes;
  LOptions: TWriteOptions;
begin
  LPath := MakeTempPath('NewFile.txt');
  LOptions := MakeDefaultWriteOptions;
  WriteTextFile(LPath, 'Hello '#$00E6, FCacheManager, LOptions);
  LBytes := ReadBytes(LPath);
  // Expect UTF-8 BOM
  Assert.AreEqual($EF, LBytes[0]);
  Assert.AreEqual($BB, LBytes[1]);
  Assert.AreEqual($BF, LBytes[2]);
  // Expect UTF-8 encoding of æ (C3 A6)
  Assert.AreEqual($C3, LBytes[Length(LBytes) - 2]);
  Assert.AreEqual($A6, LBytes[Length(LBytes) - 1]);
end;

procedure TRoundtripTests.FlushAll_WritesSidecarCache;
var
  LPath, LSidecar, LJsonText: string;
begin
  // Regression test for bug: cache should be written after FlushAll, not only
  // upon destruction of TCacheManager.
  LPath := MakeTempPath('Cached.pas');
  WriteBytes(LPath, TBytes.Create($48, $65, $6A, $20, $E6, $F8, $E5));
  ReadTextFile(LPath, FCacheManager);

  LSidecar := TPath.Combine(FTempDir, CACHE_FILE_NAME);
  // Before flush: sidecar does not exist yet (persistence is lazy)
  Assert.IsFalse(TFile.Exists(LSidecar),
    'Sidecar should not exist before FlushAll');

  FCacheManager.FlushAll;

  Assert.IsTrue(TFile.Exists(LSidecar),
    'FlushAll should have written the sidecar cache');
  LJsonText := TFile.ReadAllText(LSidecar);
  Assert.Contains(LJsonText, 'Cached.pas',
    'Cache should contain the read file');
  Assert.Contains(LJsonText, 'Windows-1252',
    'Cache should record the detected encoding');
end;

procedure TRoundtripTests.AtomicWrite_NoTempFileLeft;
var
  LPath, LTempPath: string;
  LOptions: TWriteOptions;
begin
  LPath := MakeTempPath('Atomic.txt');
  LTempPath := LPath + '.tmp';
  LOptions := MakeDefaultWriteOptions;
  WriteTextFile(LPath, 'Hello', FCacheManager, LOptions);
  Assert.IsTrue(TFile.Exists(LPath), 'File should exist after writing');
  Assert.IsFalse(TFile.Exists(LTempPath),
    'Temp file should not exist after atomic rename');
end;

procedure TRoundtripTests.CacheMerge_PreservesEntriesFromDisk;
var
  LPath1, LPath2, LSidecar, LJsonText: string;
  LCacheManager2: TCacheManager;
begin
  // Instance 1 reads file A and flushes
  LPath1 := MakeTempPath('FileA.pas');
  WriteBytes(LPath1, TBytes.Create($48, $65, $6A, $20, $E6, $F8, $E5));
  ReadTextFile(LPath1, FCacheManager);
  FCacheManager.FlushAll;

  // Instance 2 (simulated) reads file B and flushes
  LCacheManager2 := TCacheManager.Create;
  try
    LPath2 := MakeTempPath('FileB.pas');
    WriteBytes(LPath2, TBytes.Create($48, $65, $6A, $20, $E6, $F8, $E5));
    ReadTextFile(LPath2, LCacheManager2);
    LCacheManager2.FlushAll;
  finally
    LCacheManager2.Free;
  end;

  // Verify that sidecar contains both files (merge from disk)
  LSidecar := TPath.Combine(FTempDir, CACHE_FILE_NAME);
  Assert.IsTrue(TFile.Exists(LSidecar), 'Sidecar should exist');
  LJsonText := TFile.ReadAllText(LSidecar);
  Assert.Contains(LJsonText, 'FileA.pas',
    'Cache should contain FileA.pas from first instance (merged from disk)');
  Assert.Contains(LJsonText, 'FileB.pas',
    'Cache should contain FileB.pas from second instance');
end;

function TRoundtripTests.IndexOfByte(const ABytes: TBytes; AByte: Byte): Integer;
var
  I: Integer;
begin
  for I := 0 to High(ABytes) do
    if ABytes[I] = AByte then
      Exit(I);
  Result := -1;
end;

procedure TRoundtripTests.AsciiFile_NonAsciiContent_UpgradesToWindows1252;
var
  LPath: string;
  LBytes: TBytes;
  LResult: TWriteResult;
begin
  // Regression: an ASCII file receiving a Danish character was written as
  // BOM-less UTF-8 (C3 B8) while the response still claimed "ASCII".
  LPath := MakeTempPath('Ascii.pas');
  WriteBytes(LPath, TEncoding.ASCII.GetBytes('// X'#13#10));
  Assert.AreEqual(TEncodingId.Ascii, ReadTextFile(LPath, FCacheManager).EncodingId);

  LResult := WriteTextFile(LPath, '// '#$00F8#13#10, FCacheManager, MakeDefaultWriteOptions);

  LBytes := ReadBytes(LPath);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId);
  Assert.AreEqual(TEncodingId.Ascii, LResult.UpgradedFrom);
  Assert.IsTrue(Length(LResult.Warnings) > 0, 'Upgrade must be reported as a warning');
  Assert.IsFalse(LResult.HasBom);
  Assert.AreEqual(3, IndexOfByte(LBytes, $F8), 'The character must be stored as the single byte F8');
  Assert.AreEqual(-1, IndexOfByte(LBytes, $C3), 'No UTF-8 lead byte expected');
  Assert.AreEqual(TEncodingId.Windows1252, ReadTextFile(LPath, FCacheManager).EncodingId);
end;

procedure TRoundtripTests.AsciiFile_NeverRead_NonAsciiContent_UpgradesToWindows1252;
var
  LPath: string;
  LBytes: TBytes;
  LResult: TWriteResult;
begin
  LPath := MakeTempPath('NeverRead.pas');
  WriteBytes(LPath, TEncoding.ASCII.GetBytes('// X'#13#10));

  LResult := WriteTextFile(LPath, '// aktiv'#$00E9'r'#13#10, FCacheManager,
    MakeDefaultWriteOptions);

  LBytes := ReadBytes(LPath);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId);
  Assert.AreEqual(TEncodingId.Ascii, LResult.UpgradedFrom);
  Assert.IsTrue(IndexOfByte(LBytes, $E9) > 0, 'The character must be stored as E9');
  Assert.AreEqual(-1, IndexOfByte(LBytes, $C3));
end;

procedure TRoundtripTests.ExplicitAscii_NonAsciiContent_RaisesAndKeepsFile;
var
  LPath: string;
  LOptions: TWriteOptions;
begin
  LPath := MakeTempPath('Explicit.txt');
  WriteBytes(LPath, TEncoding.ASCII.GetBytes('abc'));
  LOptions := MakeDefaultWriteOptions;
  LOptions.EncodingOverride := TEncodingId.Ascii;

  Assert.WillRaise(
    procedure
    begin
      WriteTextFile(LPath, 'ab'#$00F8, FCacheManager, LOptions);
    end,
    EUnsupportedCharsError);

  Assert.AreEqual(3, Integer(Length(ReadBytes(LPath))), 'File must be left untouched');
end;

procedure TRoundtripTests.Windows1252_UnrepresentableChar_Raises;
var
  LPath: string;
  LOptions: TWriteOptions;
  LRaised: Boolean;
begin
  LPath := MakeTempPath('Cp1252.txt');
  LOptions := MakeDefaultWriteOptions;
  LOptions.EncodingOverride := TEncodingId.Windows1252;
  LRaised := False;
  try
    // U+0394 GREEK CAPITAL DELTA has no Windows-1252 code point
    WriteTextFile(LPath, 'x'#$0394'y'#$0394, FCacheManager, LOptions);
  except
    on E: EUnsupportedCharsError do
    begin
      LRaised := True;
      Assert.AreEqual(2, E.CharCount);
      Assert.AreEqual(TEncodingId.Windows1252, E.EncodingId);
    end;
  end;
  Assert.IsTrue(LRaised, 'EUnsupportedCharsError expected');
  Assert.IsFalse(TFile.Exists(LPath), 'Nothing may be written');
end;

procedure TRoundtripTests.Windows1252_UnrepresentableEmoji_CountsOnceAndSamplesWholeChar;
const
  // U+1F600 GRINNING FACE as a UTF-16 surrogate pair
  EMOJI = #$D83D#$DE00;
var
  LPath: string;
  LOptions: TWriteOptions;
  LRaised: Boolean;
begin
  LPath := MakeTempPath('Emoji.txt');
  LOptions := MakeDefaultWriteOptions;
  LOptions.EncodingOverride := TEncodingId.Windows1252;
  LRaised := False;
  try
    WriteTextFile(LPath, 'a' + EMOJI + 'b', FCacheManager, LOptions);
  except
    on E: EUnsupportedCharsError do
    begin
      LRaised := True;
      Assert.AreEqual(1, E.CharCount, 'A surrogate pair is one character');
      Assert.AreEqual(EMOJI, E.FirstSample, 'Sample must contain the whole code point');
    end;
  end;
  Assert.IsTrue(LRaised, 'EUnsupportedCharsError expected');
end;

procedure TRoundtripTests.AsciiFile_HasBomTrue_WritesUtf8WithBom;
var
  LPath: string;
  LBytes: TBytes;
  LOptions: TWriteOptions;
  LResult: TWriteResult;
begin
  // Regression: hasBom true was ignored when the content was pure ASCII.
  LPath := MakeTempPath('AsciiBom.pas');
  WriteBytes(LPath, TEncoding.ASCII.GetBytes('unit A;'#13#10));
  LOptions := MakeDefaultWriteOptions;
  LOptions.HasBomOverride := 1;

  LResult := WriteTextFile(LPath, 'unit B;'#13#10, FCacheManager, LOptions);

  LBytes := ReadBytes(LPath);
  Assert.AreEqual(TEncodingId.Utf8, LResult.EncodingId);
  Assert.IsTrue(LResult.HasBom);
  Assert.AreEqual($EF, LBytes[0]);
  Assert.AreEqual($BB, LBytes[1]);
  Assert.AreEqual($BF, LBytes[2]);
end;

procedure TRoundtripTests.PatternOverride_NeverReadFile_UsesOverride;
var
  LPath, LRelative: string;
  LCache: TEncodingCache;
  LBytes: TBytes;
  LResult: TWriteResult;
begin
  LPath := MakeTempPath('Override.pas');
  WriteBytes(LPath, TEncoding.ASCII.GetBytes('// X'#13#10));
  FCacheManager.Resolve(LPath, LCache, LRelative);
  LCache.SetPatternOverride('*.pas', TEncodingId.Windows1252);

  LResult := WriteTextFile(LPath, '// '#$00F8#13#10, FCacheManager, MakeDefaultWriteOptions);

  LBytes := ReadBytes(LPath);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId);
  Assert.AreEqual(TEncodingSource.PatternOverride, LResult.Source);
  Assert.AreEqual(TEncodingId.Unknown, LResult.UpgradedFrom, 'An override is not an upgrade');
  Assert.AreEqual(3, IndexOfByte(LBytes, $F8));
end;

procedure TRoundtripTests.ExternalEncodingChange_AfterCache_IsHonoured;
var
  LPath: string;
  LBytes: TBytes;
  LResult: TWriteResult;
begin
  LPath := MakeTempPath('External.pas');
  WriteBytes(LPath, TBytes.Create($48, $65, $6A, $20, $E6, $F8, $E5));
  Assert.AreEqual(TEncodingId.Windows1252, ReadTextFile(LPath, FCacheManager).EncodingId);

  // Another tool converts the file to UTF-8 with BOM
  WriteBytes(LPath, TBytes.Create($EF, $BB, $BF, $48, $65, $6A, $20, $C3, $A6));

  LResult := WriteTextFile(LPath, 'Hej '#$00F8, FCacheManager, MakeDefaultWriteOptions);

  LBytes := ReadBytes(LPath);
  Assert.AreEqual(TEncodingId.Utf8, LResult.EncodingId);
  Assert.IsTrue(LResult.HasBom);
  Assert.AreEqual($EF, LBytes[0]);
  Assert.AreEqual($C3, LBytes[Length(LBytes) - 2]);
  Assert.AreEqual($B8, LBytes[Length(LBytes) - 1]);
end;

procedure TRoundtripTests.ExplicitEncoding_PreservesLineEndingAndBom;
var
  LPath: string;
  LBytes: TBytes;
  LOptions: TWriteOptions;
  LResult: TWriteResult;
begin
  // Regression: passing only "encoding" also reset line endings to CRLF and
  // dropped an existing BOM.
  LPath := MakeTempPath('Lf.txt');
  WriteBytes(LPath, TBytes.Create($EF, $BB, $BF, $61, $0A, $62, $0A));
  LOptions := MakeDefaultWriteOptions;
  LOptions.EncodingOverride := TEncodingId.Utf8;

  LResult := WriteTextFile(LPath, 'a'#10'c'#10, FCacheManager, LOptions);

  LBytes := ReadBytes(LPath);
  Assert.AreEqual(TLineEnding.Lf, LResult.LineEnding);
  Assert.IsTrue(LResult.HasBom);
  Assert.AreEqual(7, Integer(Length(LBytes)));
  Assert.AreEqual(-1, IndexOfByte(LBytes, $0D), 'No CR may be introduced');
end;

procedure TRoundtripTests.ExplicitUnicodeEncoding_FromAnsi_AddsBomKeepsLf;
var
  LPath: string;
  LBytes: TBytes;
  LOptions: TWriteOptions;
  LResult: TWriteResult;
begin
  LPath := MakeTempPath('AnsiLf.txt');
  WriteBytes(LPath, TBytes.Create($E6, $0A, $F8, $0A));
  LOptions := MakeDefaultWriteOptions;
  LOptions.EncodingOverride := TEncodingId.Utf8;

  LResult := WriteTextFile(LPath, #$00E6#10#$00F8#10, FCacheManager, LOptions);

  LBytes := ReadBytes(LPath);
  Assert.AreEqual(TLineEnding.Lf, LResult.LineEnding);
  Assert.IsTrue(LResult.HasBom, 'Switching from 8-bit to UTF-8 must add a BOM');
  Assert.AreEqual($EF, LBytes[0]);
  Assert.AreEqual(-1, IndexOfByte(LBytes, $0D));
end;

procedure TRoundtripTests.DryRun_DoesNotWrite;
var
  LPath, LNewPath: string;
  LOptions: TWriteOptions;
  LResult: TWriteResult;
begin
  LPath := MakeTempPath('Dry.pas');
  WriteBytes(LPath, TEncoding.ASCII.GetBytes('abc'));
  LOptions := MakeDefaultWriteOptions;
  LOptions.DryRun := True;

  LResult := WriteTextFile(LPath, 'ab'#$00F8, FCacheManager, LOptions);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.EncodingId,
    'A dry run must report the encoding a real write would use');
  Assert.AreEqual(TEncodingId.Ascii, LResult.UpgradedFrom);
  Assert.AreEqual('abc', TEncoding.ASCII.GetString(ReadBytes(LPath)));

  LNewPath := MakeTempPath('DryNew.pas');
  WriteTextFile(LNewPath, 'x', FCacheManager, LOptions);
  Assert.IsFalse(TFile.Exists(LNewPath), 'A dry run must not create files');
end;

procedure TRoundtripTests.Sidecar_UsesNewName;
begin
  Assert.AreEqual('.encoding-mcp.json', CACHE_FILE_NAME);
  WriteBytes(MakeTempPath('A.pas'), TBytes.Create($E6));
  ReadTextFile(MakeTempPath('A.pas'), FCacheManager);
  FCacheManager.FlushAll;
  Assert.IsTrue(TFile.Exists(MakeTempPath('.encoding-mcp.json')));
  Assert.IsFalse(TFile.Exists(MakeTempPath(LEGACY_CACHE_FILE_NAME)));
end;

procedure TRoundtripTests.LegacySidecar_IsReadAndMigratedOnSave;
var
  LLegacy, LNew, LRelative: string;
  LCache: TEncodingCache;
  LId: TEncodingId;
begin
  LLegacy := MakeTempPath(LEGACY_CACHE_FILE_NAME);
  LNew := MakeTempPath(CACHE_FILE_NAME);
  TFile.WriteAllText(LLegacy,
    '{"version":1,"files":{},"overrides":{"*.pas":"Windows-1252"}}', TEncoding.UTF8);

  FCacheManager.Resolve(MakeTempPath('Unit1.pas'), LCache, LRelative);
  Assert.IsTrue(LCache.TryGetPatternOverride(LRelative, LId),
    'Overrides from the legacy sidecar must be honoured');
  Assert.AreEqual(TEncodingId.Windows1252, LId);

  FCacheManager.FlushAll;

  Assert.IsTrue(TFile.Exists(LNew), 'The new sidecar must be written');
  Assert.IsFalse(TFile.Exists(LLegacy), 'The legacy sidecar must be removed after migration');
  Assert.Contains(TFile.ReadAllText(LNew), 'Windows-1252');
end;

procedure TRoundtripTests.BothSidecars_NewWinsAndLegacyIsKept;
var
  LLegacy, LRelative: string;
  LCache: TEncodingCache;
  LId: TEncodingId;
begin
  LLegacy := MakeTempPath(LEGACY_CACHE_FILE_NAME);
  TFile.WriteAllText(LLegacy,
    '{"version":1,"files":{},"overrides":{"*.pas":"Windows-1252"}}', TEncoding.UTF8);
  TFile.WriteAllText(MakeTempPath(CACHE_FILE_NAME),
    '{"version":1,"files":{},"overrides":{"*.pas":"UTF-8"}}', TEncoding.UTF8);

  FCacheManager.Resolve(MakeTempPath('Unit1.pas'), LCache, LRelative);
  Assert.IsTrue(LCache.TryGetPatternOverride(LRelative, LId));
  Assert.AreEqual(TEncodingId.Utf8, LId, 'The new sidecar must win');

  FCacheManager.FlushAll;
  Assert.IsTrue(TFile.Exists(LLegacy), 'The legacy file is left for the user to resolve');
end;

procedure TRoundtripTests.LegacySidecar_DeleteFails_MigrationStillSucceeds;
var
  LLegacy, LNew, LRelative: string;
  LCache: TEncodingCache;
  LId: TEncodingId;
  LLock: TFileStream;
begin
  LLegacy := MakeTempPath(LEGACY_CACHE_FILE_NAME);
  LNew := MakeTempPath(CACHE_FILE_NAME);
  TFile.WriteAllText(LLegacy,
    '{"version":1,"files":{},"overrides":{"*.pas":"Windows-1252"}}', TEncoding.UTF8);
  FCacheManager.Resolve(MakeTempPath('Unit1.pas'), LCache, LRelative);

  // An open handle without share-delete makes DeleteFile fail; migration must
  // log the problem and still produce the new sidecar.
  LLock := TFileStream.Create(LLegacy, fmOpenRead or fmShareDenyNone);
  try
    FCacheManager.FlushAll;
    Assert.IsTrue(TFile.Exists(LNew), 'The new sidecar must be written');
    Assert.IsTrue(TFile.Exists(LLegacy), 'The locked legacy sidecar cannot be deleted');
  finally
    LLock.Free;
  end;
  Assert.Contains(TFile.ReadAllText(LNew), 'Windows-1252');

  // Subsequent saves must not keep retrying the migration: with nothing
  // pending, a flush writes no new sidecar.
  TFile.Delete(LNew);
  FCacheManager.FlushAll;
  Assert.IsFalse(TFile.Exists(LNew), 'Migration must be marked complete');
  Assert.IsTrue(LCache.TryGetPatternOverride(LRelative, LId));
  Assert.AreEqual(TEncodingId.Windows1252, LId);
end;

initialization
  TDUnitX.RegisterTestFixture(TRoundtripTests);

end.
