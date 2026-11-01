unit FileIO.Atomic;

/// <summary>
///   Primitives shared by every code path that replaces a file on disk:
///   a cross-process lock, unique temporary file names and an atomic
///   temp-to-final replacement. Writer, editor and sidecar cache all go
///   through this unit so two server instances (or a server and another
///   tool using the same convention) never interleave their writes.
/// </summary>

interface

uses
  System.SysUtils;

const
  /// <summary>How long a writer waits for a lock before giving up.</summary>
  LOCK_TIMEOUT_MS = 2000;
  /// <summary>Suffix of the lock file placed next to the file being written.</summary>
  LOCK_FILE_SUFFIX = '.lock';
  /// <summary>Suffix of the temporary file that is renamed over the target.</summary>
  TEMP_FILE_SUFFIX = '.tmp';

type
  /// <summary>Raised when the lock for a file is not obtained within the timeout.</summary>
  EFileLockedError = class(Exception)
  strict private
    FPath: string;
    FTimeoutMs: Integer;
  public
    constructor Create(const APath: string; ATimeoutMs: Integer);
    property Path: string read FPath;
    property TimeoutMs: Integer read FTimeoutMs;
  end;

  /// <summary>
  ///   Exclusive, cross-process lock on a file. The lock is a sibling file
  ///   "&lt;file&gt;.lock" opened with CREATE_NEW, no sharing and
  ///   FILE_FLAG_DELETE_ON_CLOSE, so it is removed by the OS when the handle
  ///   is closed - also when the process crashes - and can never go stale.
  ///   The constructor retries with exponential backoff until ATimeoutMs
  ///   elapses and then raises EFileLockedError. Destroy releases the lock.
  /// </summary>
  TFileLock = class
  strict private
    FHandle: THandle;
    FLockPath: string;
    procedure Acquire(ATimeoutMs: Integer);
  public
    constructor Create(const APath: string; ATimeoutMs: Integer = LOCK_TIMEOUT_MS);
    destructor Destroy; override;
    property LockPath: string read FLockPath;
  end;

/// <summary>Path of the lock file that guards APath.</summary>
function LockFileName(const APath: string): string;

/// <summary>
///   A temporary file name next to APath that is unique per process and call:
///   "&lt;file&gt;.&lt;pid&gt;-&lt;guid&gt;.tmp". Two instances writing the
///   same file therefore never collide on the temp file.
/// </summary>
function MakeTempFileName(const APath: string): string;

/// <summary>
///   True for the transient files this unit creates (lock files and
///   temporary files), so directory listings and sidecar logic can skip
///   them. Only the file name is inspected, not the directory.
/// </summary>
function IsTransientFileName(const AFileName: string): Boolean;

/// <summary>
///   Replaces APath with ATempPath atomically (MoveFileEx with
///   MOVEFILE_REPLACE_EXISTING, write-through). Falls back to delete+move
///   when the rename is refused, e.g. by an antivirus scanner. If both fail
///   the temp file is removed and the exception propagates.
/// </summary>
procedure ReplaceFileAtomic(const ATempPath, APath: string);

/// <summary>
///   Writes ABytes to a unique temp file next to APath and renames it over
///   APath. Callers that must not interleave with other writers hold a
///   TFileLock on APath around this call.
/// </summary>
procedure WriteBytesAtomic(const APath: string; const ABytes: TBytes);

implementation

uses
  System.Classes,
  System.IOUtils,
  System.Diagnostics,
  System.Math,
  Winapi.Windows,
  MCP.Logging;

const
  // Backoff between lock attempts: starts short so uncontended waits are
  // cheap, caps so a long wait does not hammer the file system.
  LOCK_RETRY_INITIAL_MS = 10;
  LOCK_RETRY_MAX_MS = 200;

{ EFileLockedError }

constructor EFileLockedError.Create(const APath: string; ATimeoutMs: Integer);
begin
  inherited CreateFmt(
    'The file is being written by another process and the lock was not ' +
    'released within %d ms: %s. Nothing was written. Retry the operation.',
    [ATimeoutMs, APath]);
  FPath := APath;
  FTimeoutMs := ATimeoutMs;
end;

{ TFileLock }

constructor TFileLock.Create(const APath: string; ATimeoutMs: Integer);
begin
  inherited Create;
  FHandle := INVALID_HANDLE_VALUE;
  FLockPath := LockFileName(APath);
  Acquire(ATimeoutMs);
end;

destructor TFileLock.Destroy;
begin
  if FHandle <> INVALID_HANDLE_VALUE then
  begin
    // FILE_FLAG_DELETE_ON_CLOSE removes the lock file here
    CloseHandle(FHandle);
    FHandle := INVALID_HANDLE_VALUE;
  end;
  inherited;
end;

procedure TFileLock.Acquire(ATimeoutMs: Integer);
var
  LWatch: TStopwatch;
  LDelayMs: Integer;
  LError: DWORD;
begin
  LWatch := TStopwatch.StartNew;
  LDelayMs := LOCK_RETRY_INITIAL_MS;
  repeat
    FHandle := CreateFile(PChar(FLockPath), GENERIC_WRITE, 0, nil, CREATE_NEW,
      FILE_ATTRIBUTE_TEMPORARY or FILE_ATTRIBUTE_HIDDEN or FILE_FLAG_DELETE_ON_CLOSE, 0);
    if FHandle <> INVALID_HANDLE_VALUE then
      Exit;
    LError := GetLastError;
    // FILE_EXISTS: another holder. SHARING_VIOLATION / ACCESS_DENIED: the
    // previous holder's delete-on-close is still pending. Anything else
    // (path not found, read-only medium) will not resolve by waiting.
    if (LError <> ERROR_FILE_EXISTS) and (LError <> ERROR_SHARING_VIOLATION) and
       (LError <> ERROR_ACCESS_DENIED) then
      RaiseLastOSError(LError, ' (' + FLockPath + ')');
    if LWatch.ElapsedMilliseconds >= ATimeoutMs then
      raise EFileLockedError.Create(
        Copy(FLockPath, 1, Length(FLockPath) - Length(LOCK_FILE_SUFFIX)), ATimeoutMs);
    Sleep(LDelayMs);
    LDelayMs := Min(LDelayMs * 2, LOCK_RETRY_MAX_MS);
  until False;
end;

function LockFileName(const APath: string): string;
begin
  Result := APath + LOCK_FILE_SUFFIX;
end;

function MakeTempFileName(const APath: string): string;
var
  LGuid: TGUID;
begin
  CreateGUID(LGuid);
  Result := Format('%s.%d-%s%s', [APath, GetCurrentProcessId,
    LowerCase(GUIDToString(LGuid).Replace('{', '').Replace('}', '').Replace('-', '')),
    TEMP_FILE_SUFFIX]);
end;

function IsAllOfClass(const AText: string; const AAllowed: TSysCharSet): Boolean;
var
  LChar: Char;
begin
  Result := AText <> '';
  for LChar in AText do
    if not CharInSet(LChar, AAllowed) then
      Exit(False);
end;

function IsTransientFileName(const AFileName: string): Boolean;
var
  LCore, LTail, LPid, LGuid: string;
  LDot, LDash: Integer;
begin
  if AFileName.EndsWith(LOCK_FILE_SUFFIX, True) then
    Exit(True);
  if not AFileName.EndsWith(TEMP_FILE_SUFFIX, True) then
    Exit(False);
  // Expect "<name>.<pid>-<32 hex digits>.tmp"
  LCore := Copy(AFileName, 1, Length(AFileName) - Length(TEMP_FILE_SUFFIX));
  LDot := LCore.LastIndexOf('.');
  if LDot < 0 then
    Exit(False);
  LTail := LCore.Substring(LDot + 1);
  LDash := LTail.IndexOf('-');
  if LDash < 0 then
    Exit(False);
  LPid := LTail.Substring(0, LDash);
  LGuid := LTail.Substring(LDash + 1);
  Result := IsAllOfClass(LPid, ['0'..'9']) and (Length(LGuid) = 32) and
    IsAllOfClass(LGuid, ['0'..'9', 'a'..'f']);
end;

procedure ReplaceFileAtomic(const ATempPath, APath: string);
var
  LMoved: Boolean;
begin
  LMoved := False;
  try
    if MoveFileEx(PChar(ATempPath), PChar(APath),
         MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      LMoved := True
    else
    begin
      TLog.Warning('MoveFileEx failed for %s, trying fallback: %s',
        [APath, SysErrorMessage(GetLastError)]);
      if TFile.Exists(APath) then
        TFile.Delete(APath);
      TFile.Move(ATempPath, APath);
      LMoved := True;
    end;
  finally
    if (not LMoved) and TFile.Exists(ATempPath) then
      TFile.Delete(ATempPath);
  end;
end;

procedure WriteBytesAtomic(const APath: string; const ABytes: TBytes);
var
  LTempPath: string;
  LStream: TFileStream;
begin
  LTempPath := MakeTempFileName(APath);
  try
    LStream := TFileStream.Create(LTempPath, fmCreate or fmShareExclusive);
    try
      if Length(ABytes) > 0 then
        LStream.WriteBuffer(ABytes[0], Length(ABytes));
    finally
      LStream.Free;
    end;
  except
    if TFile.Exists(LTempPath) then
      TFile.Delete(LTempPath);
    raise;
  end;
  ReplaceFileAtomic(LTempPath, APath);
end;

end.
