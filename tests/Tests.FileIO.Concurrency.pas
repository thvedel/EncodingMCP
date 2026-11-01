unit Tests.FileIO.Concurrency;

/// <summary>
///   Tests for the cross-process write protection in FileIO.Atomic and its
///   use by the writer and the sidecar cache: unique temp names, the lock
///   file, RequireUnchangedSince and merge-under-lock of the sidecar.
/// </summary>

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Encoding.CacheManager;

type
  [TestFixture]
  TConcurrencyTests = class
  strict private
    FTempDir: string;
    FCacheManager: TCacheManager;
    function MakeTempPath(const AFileName: string): string;
    procedure WriteUtf8File(const APath, AContent: string);
    function ReadFileText(const APath: string): string;
    function TransientFileCount: Integer;
    // Holds the lock on APath in a background thread for AHoldMs and returns
    // once the lock is actually held. The caller waits for the thread.
    function HoldLockInBackground(const APath: string; AHoldMs: Integer): TThread;
    // Acts as a separate server instance: own cache objects, writes
    // ENTRIES_PER_INSTANCE entries named inst<AIndex>_file<K>.txt and saves
    // after each one.
    function MakeInstanceProc(AIndex: Integer): TProc;
  public
    [Setup]
    procedure Setup;
    [Teardown]
    procedure Teardown;

    [Test]
    procedure TempFileName_IsUniquePerCall;
    [Test]
    procedure IsTransientFileName_RecognisesLockAndTempNames;
    [Test]
    procedure Lock_HeldByOther_WaitsUntilReleased;
    [Test]
    procedure Lock_Timeout_RaisesEFileLockedError;
    [Test]
    procedure Lock_Destroy_RemovesLockFile;
    [Test]
    procedure Write_RequireUnchangedSince_Stale_RaisesAndLeavesFileIntact;
    [Test]
    procedure Write_RequireUnchangedSince_Fresh_Writes;
    [Test]
    procedure Write_RequireUnchangedSince_DryRun_DoesNotCheck;
    [Test]
    procedure Write_WhileLocked_RaisesEFileLockedError;
    [Test]
    procedure Write_FailingConversion_ReleasesLock;
    [Test]
    procedure Write_LeavesNoTransientFiles;
    [Test]
    procedure CacheSave_ParallelInstances_KeepAllEntries;
  end;

implementation

uses
  System.IOUtils,
  System.Diagnostics,
  System.Threading,
  Encoding.Types,
  Encoding.Cache,
  FileIO.Atomic,
  FileIO.Writer;

const
  HEX32 = '0123456789abcdef0123456789abcdef';
  INSTANCES = 4;
  ENTRIES_PER_INSTANCE = 10;

{ TConcurrencyTests }

function TConcurrencyTests.MakeTempPath(const AFileName: string): string;
begin
  Result := TPath.Combine(FTempDir, AFileName);
end;

procedure TConcurrencyTests.WriteUtf8File(const APath, AContent: string);
begin
  TFile.WriteAllText(APath, AContent, TEncoding.UTF8);
end;

function TConcurrencyTests.ReadFileText(const APath: string): string;
begin
  Result := TFile.ReadAllText(APath, TEncoding.UTF8);
end;

function TConcurrencyTests.TransientFileCount: Integer;
var
  LFile: string;
begin
  Result := 0;
  for LFile in TDirectory.GetFiles(FTempDir) do
    if IsTransientFileName(TPath.GetFileName(LFile)) then
      Inc(Result);
end;

function TConcurrencyTests.HoldLockInBackground(const APath: string;
  AHoldMs: Integer): TThread;
var
  LAcquired: TEvent;
begin
  LAcquired := TEvent.Create(nil, True, False, '');
  try
    Result := TThread.CreateAnonymousThread(
      procedure
      var
        LLock: TFileLock;
      begin
        LLock := TFileLock.Create(APath);
        try
          LAcquired.SetEvent;
          Sleep(AHoldMs);
        finally
          LLock.Free;
        end;
      end);
    Result.FreeOnTerminate := False;
    Result.Start;
    Assert.AreEqual(TWaitResult.wrSignaled, LAcquired.WaitFor(5000),
      'background thread did not acquire the lock');
  finally
    LAcquired.Free;
  end;
end;

function TConcurrencyTests.MakeInstanceProc(AIndex: Integer): TProc;
var
  LTempDir: string;
begin
  LTempDir := FTempDir;
  Result :=
    procedure
    var
      LManager: TCacheManager;
      LCache: TEncodingCache;
      LRelative: string;
      LEntry: TCacheEntry;
      K: Integer;
    begin
      LManager := TCacheManager.Create;
      try
        for K := 0 to ENTRIES_PER_INSTANCE - 1 do
        begin
          LManager.Resolve(TPath.Combine(LTempDir,
            Format('inst%d_file%d.txt', [AIndex, K])), LCache, LRelative);
          LEntry := Default(TCacheEntry);
          LEntry.EncodingId := TEncodingId.Windows1252;
          LEntry.LineEnding := TLineEnding.CrLf;
          LEntry.DetectedAt := Now;
          LCache.Put(LRelative, LEntry);
          LCache.Save;
        end;
      finally
        LManager.Free;
      end;
    end;
end;

procedure TConcurrencyTests.Setup;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'EncodingMCPTests_Conc_' +
    FormatDateTime('yyyymmddhhnnsszzz', Now));
  TDirectory.CreateDirectory(FTempDir);
  TDirectory.CreateDirectory(TPath.Combine(FTempDir, '.git'));
  FCacheManager := TCacheManager.Create;
end;

procedure TConcurrencyTests.Teardown;
begin
  FreeAndNil(FCacheManager);
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

procedure TConcurrencyTests.TempFileName_IsUniquePerCall;
var
  LPath, LFirst, LSecond: string;
begin
  LPath := MakeTempPath('a.txt');
  LFirst := MakeTempFileName(LPath);
  LSecond := MakeTempFileName(LPath);
  Assert.AreNotEqual(LFirst, LSecond);
  Assert.IsTrue(LFirst.StartsWith(LPath + '.'), LFirst);
  Assert.IsTrue(LFirst.EndsWith(TEMP_FILE_SUFFIX), LFirst);
  Assert.IsTrue(IsTransientFileName(TPath.GetFileName(LFirst)), LFirst);
  Assert.IsTrue(IsTransientFileName(TPath.GetFileName(LSecond)), LSecond);
end;

procedure TConcurrencyTests.IsTransientFileName_RecognisesLockAndTempNames;
begin
  Assert.IsTrue(IsTransientFileName('Unit1.pas.lock'));
  Assert.IsTrue(IsTransientFileName('.encoding-mcp.json.lock'));
  Assert.IsTrue(IsTransientFileName('Unit1.pas.1234-' + HEX32 + '.tmp'));
  Assert.IsTrue(IsTransientFileName(TPath.GetFileName(MakeTempFileName('x.dfm'))));
  // Ordinary files and user-owned .tmp files are not transient
  Assert.IsFalse(IsTransientFileName('Unit1.pas'));
  Assert.IsFalse(IsTransientFileName('notes.tmp'));
  Assert.IsFalse(IsTransientFileName('Unit1.pas.tmp'));
  Assert.IsFalse(IsTransientFileName('Unit1.pas.abc-' + HEX32 + '.tmp'));
  Assert.IsFalse(IsTransientFileName('Unit1.pas.1234-shortguid.tmp'));
  Assert.IsFalse(IsTransientFileName('locker'));
end;

procedure TConcurrencyTests.Lock_HeldByOther_WaitsUntilReleased;
const
  HOLD_MS = 300;
var
  LPath: string;
  LThread: TThread;
  LWatch: TStopwatch;
  LLock: TFileLock;
begin
  LPath := MakeTempPath('wait.txt');
  LThread := HoldLockInBackground(LPath, HOLD_MS);
  try
    LWatch := TStopwatch.StartNew;
    LLock := TFileLock.Create(LPath);
    try
      // Acquired only after the holder released it, and well before the timeout
      Assert.IsTrue(LWatch.ElapsedMilliseconds >= HOLD_MS div 2,
        Format('acquired after %d ms', [LWatch.ElapsedMilliseconds]));
      Assert.IsTrue(LWatch.ElapsedMilliseconds < LOCK_TIMEOUT_MS,
        Format('acquired after %d ms', [LWatch.ElapsedMilliseconds]));
    finally
      LLock.Free;
    end;
  finally
    LThread.WaitFor;
    LThread.Free;
  end;
end;

procedure TConcurrencyTests.Lock_Timeout_RaisesEFileLockedError;
var
  LPath: string;
  LThread: TThread;
begin
  LPath := MakeTempPath('timeout.txt');
  LThread := HoldLockInBackground(LPath, 1000);
  try
    Assert.WillRaise(
      procedure
      begin
        TFileLock.Create(LPath, 150).Free;
      end, EFileLockedError);
    Assert.IsTrue(TFile.Exists(LockFileName(LPath)), 'lock file present while held');
  finally
    LThread.WaitFor;
    LThread.Free;
  end;
  Assert.IsFalse(TFile.Exists(LockFileName(LPath)), 'lock file removed after release');
end;

procedure TConcurrencyTests.Lock_Destroy_RemovesLockFile;
var
  LPath: string;
  LLock: TFileLock;
begin
  LPath := MakeTempPath('cleanup.txt');
  LLock := TFileLock.Create(LPath);
  Assert.IsTrue(TFile.Exists(LLock.LockPath));
  LLock.Free;
  Assert.IsFalse(TFile.Exists(LockFileName(LPath)));
  // Re-acquiring immediately must succeed without waiting for the timeout
  TFileLock.Create(LPath, 50).Free;
end;

procedure TConcurrencyTests.Write_RequireUnchangedSince_Stale_RaisesAndLeavesFileIntact;
var
  LPath: string;
  LOptions: TWriteOptions;
begin
  LPath := MakeTempPath('stale.txt');
  WriteUtf8File(LPath, 'original');
  LOptions := MakeDefaultWriteOptions;
  // Pretend the file was read a minute before its current write time
  LOptions.RequireUnchangedSince := TFile.GetLastWriteTime(LPath) - (60 / SecsPerDay);
  Assert.WillRaise(
    procedure
    begin
      WriteTextFile(LPath, 'replacement', FCacheManager, LOptions);
    end, EFileModifiedError);
  Assert.AreEqual('original', ReadFileText(LPath));
  Assert.AreEqual(0, TransientFileCount);
end;

procedure TConcurrencyTests.Write_RequireUnchangedSince_Fresh_Writes;
var
  LPath: string;
  LOptions: TWriteOptions;
begin
  LPath := MakeTempPath('fresh.txt');
  WriteUtf8File(LPath, 'original');
  LOptions := MakeDefaultWriteOptions;
  LOptions.RequireUnchangedSince := TFile.GetLastWriteTime(LPath);
  WriteTextFile(LPath, 'replacement', FCacheManager, LOptions);
  Assert.AreEqual('replacement', ReadFileText(LPath));
end;

procedure TConcurrencyTests.Write_RequireUnchangedSince_DryRun_DoesNotCheck;
var
  LPath: string;
  LOptions: TWriteOptions;
  LResult: TWriteResult;
begin
  LPath := MakeTempPath('dryrun.txt');
  WriteUtf8File(LPath, 'original');
  LOptions := MakeDefaultWriteOptions;
  LOptions.DryRun := True;
  LOptions.RequireUnchangedSince := TFile.GetLastWriteTime(LPath) - (60 / SecsPerDay);
  LResult := WriteTextFile(LPath, 'replacement', FCacheManager, LOptions);
  Assert.IsTrue(LResult.BytesWritten > 0);
  Assert.AreEqual('original', ReadFileText(LPath));
end;

procedure TConcurrencyTests.Write_WhileLocked_RaisesEFileLockedError;
var
  LPath: string;
  LThread: TThread;
begin
  LPath := MakeTempPath('locked.txt');
  WriteUtf8File(LPath, 'original');
  // Hold the lock longer than the writer's timeout
  LThread := HoldLockInBackground(LPath, LOCK_TIMEOUT_MS + 500);
  try
    Assert.WillRaise(
      procedure
      begin
        WriteTextFile(LPath, 'replacement', FCacheManager, MakeDefaultWriteOptions);
      end, EFileLockedError);
    Assert.AreEqual('original', ReadFileText(LPath));
  finally
    LThread.WaitFor;
    LThread.Free;
  end;
end;

procedure TConcurrencyTests.Write_FailingConversion_ReleasesLock;
var
  LPath: string;
  LOptions: TWriteOptions;
begin
  LPath := MakeTempPath('release.txt');
  WriteUtf8File(LPath, 'plain');
  LOptions := MakeDefaultWriteOptions;
  LOptions.EncodingOverride := TEncodingId.Windows1252;
  Assert.WillRaise(
    procedure
    begin
      // U+4E2D cannot be represented in Windows-1252
      WriteTextFile(LPath, 'x' + #$4E2D, FCacheManager, LOptions);
    end, EUnsupportedCharsError);
  Assert.IsFalse(TFile.Exists(LockFileName(LPath)), 'lock released after exception');
  TFileLock.Create(LPath, 50).Free;
end;

procedure TConcurrencyTests.Write_LeavesNoTransientFiles;
var
  LPath: string;
begin
  LPath := MakeTempPath('clean.txt');
  WriteTextFile(LPath, 'first', FCacheManager, MakeDefaultWriteOptions);
  WriteTextFile(LPath, 'second', FCacheManager, MakeDefaultWriteOptions);
  Assert.AreEqual('second', ReadFileText(LPath));
  Assert.AreEqual(0, TransientFileCount);
end;

procedure TConcurrencyTests.CacheSave_ParallelInstances_KeepAllEntries;
var
  LTasks: array of ITask;
  I, K: Integer;
  LVerifier: TCacheManager;
  LCache: TEncodingCache;
  LRelative: string;
  LEntry: TCacheEntry;
begin
  SetLength(LTasks, INSTANCES);
  for I := 0 to INSTANCES - 1 do
    LTasks[I] := TTask.Run(MakeInstanceProc(I));
  TTask.WaitForAll(LTasks);

  // A fresh instance must see every entry written by every task
  LVerifier := TCacheManager.Create;
  try
    LVerifier.Resolve(TPath.Combine(FTempDir, 'probe.txt'), LCache, LRelative);
    for I := 0 to INSTANCES - 1 do
      for K := 0 to ENTRIES_PER_INSTANCE - 1 do
        Assert.IsTrue(LCache.TryGet(Format('inst%d_file%d.txt', [I, K]), LEntry),
          Format('entry inst%d_file%d.txt missing after parallel saves', [I, K]));
  finally
    LVerifier.Free;
  end;
  Assert.AreEqual(0, TransientFileCount);
end;

initialization
  TDUnitX.RegisterTestFixture(TConcurrencyTests);

end.
