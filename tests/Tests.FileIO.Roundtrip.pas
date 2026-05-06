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
  end;

implementation

uses
  System.IOUtils,
  System.Classes,
  Encoding.Types,
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

  LSidecar := TPath.Combine(FTempDir, '.windsurf-encoding.json');
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
  LSidecar := TPath.Combine(FTempDir, '.windsurf-encoding.json');
  Assert.IsTrue(TFile.Exists(LSidecar), 'Sidecar should exist');
  LJsonText := TFile.ReadAllText(LSidecar);
  Assert.Contains(LJsonText, 'FileA.pas',
    'Cache should contain FileA.pas from first instance (merged from disk)');
  Assert.Contains(LJsonText, 'FileB.pas',
    'Cache should contain FileB.pas from second instance');
end;

initialization
  TDUnitX.RegisterTestFixture(TRoundtripTests);

end.
