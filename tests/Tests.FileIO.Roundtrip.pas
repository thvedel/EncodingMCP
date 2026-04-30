unit Tests.FileIO.Roundtrip;

/// <summary>
///   End-to-end tests af læs/skriv round-trip via FileIO units.
///   Verificerer at en Windows-1252 fil bevarer sin encoding gennem
///   en read → modify → write cyklus.
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
  // Marker så workspace-detektion finder denne mappe som rod
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
  // 'Hej æøå' i Windows-1252
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
  // '€' i Windows-1252 er 0x80
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
  // Skriv original Windows-1252 fil
  WriteBytes(LPath, TBytes.Create($48, $65, $6A, $20, $E6, $F8, $E5));
  // Læs den (cacher encoding)
  ReadTextFile(LPath, FCacheManager);
  // Skriv nyt indhold med samme tegn
  LOptions := MakeDefaultWriteOptions;
  WriteTextFile(LPath, 'Hej '#$00E6#$00F8#$00E5, FCacheManager, LOptions);
  // Verificér at output er Windows-1252 bytes (E6 F8 E5)
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
  // Forvent UTF-8 BOM
  Assert.AreEqual($EF, LBytes[0]);
  Assert.AreEqual($BB, LBytes[1]);
  Assert.AreEqual($BF, LBytes[2]);
  // Forvent UTF-8 encoding af æ (C3 A6)
  Assert.AreEqual($C3, LBytes[Length(LBytes) - 2]);
  Assert.AreEqual($A6, LBytes[Length(LBytes) - 1]);
end;

procedure TRoundtripTests.FlushAll_WritesSidecarCache;
var
  LPath, LSidecar, LJsonText: string;
begin
  // Regressionstest for bug: cache skulle skrives efter FlushAll, ikke først
  // ved destruction af TCacheManager.
  LPath := MakeTempPath('Cached.pas');
  WriteBytes(LPath, TBytes.Create($48, $65, $6A, $20, $E6, $F8, $E5));
  ReadTextFile(LPath, FCacheManager);

  LSidecar := TPath.Combine(FTempDir, '.windsurf-encoding.json');
  // Før flush: sidecar findes ikke endnu (persistens er lazy)
  Assert.IsFalse(TFile.Exists(LSidecar),
    'Sidecar burde ikke eksistere før FlushAll');

  FCacheManager.FlushAll;

  Assert.IsTrue(TFile.Exists(LSidecar),
    'FlushAll skulle have skrevet sidecar-cachen');
  LJsonText := TFile.ReadAllText(LSidecar);
  Assert.Contains(LJsonText, 'Cached.pas',
    'Cache burde indeholde den læste fil');
  Assert.Contains(LJsonText, 'Windows-1252',
    'Cache burde registrere den detekterede encoding');
end;

initialization
  TDUnitX.RegisterTestFixture(TRoundtripTests);

end.
