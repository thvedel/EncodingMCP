unit Encoding.Cache;

/// <summary>
///   Persistent sidecar cache that remembers detected/manually set encoding per
///   file and pattern overrides. The cache lives as a JSON file
///   (.encoding-mcp.json) in a workspace directory. A legacy
///   .windsurf-encoding.json is read and migrated on the next save.
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  Encoding.Types;

const
  CACHE_FILE_NAME = '.encoding-mcp.json';
  /// <summary>Former sidecar name; migrated to CACHE_FILE_NAME on save.</summary>
  LEGACY_CACHE_FILE_NAME = '.windsurf-encoding.json';
  CACHE_VERSION = 1;

type
  /// <summary>Raised when an override pattern uses unsupported syntax.</summary>
  EInvalidOverridePattern = class(Exception);

  /// <summary>A single entry in the file cache.</summary>
  TCacheEntry = record
    EncodingId: TEncodingId;
    HasBom: Boolean;
    LineEnding: TLineEnding;
    Manual: Boolean; // Set via set_encoding_override
    DetectedAt: TDateTime;
    FileSize: Int64;      // Size at detection time (for staleness check)
    FileTimestamp: TDateTime; // Last-modified at detection time
  end;

  /// <summary>
  ///   In-memory + persistent cache for a single sidecar directory. Caches are
  ///   linked to the sidecar of an enclosing directory through Parent, so
  ///   pattern overrides are looked up from the nearest to the outermost sidecar.
  /// </summary>
  TEncodingCache = class
  strict private
    FWorkspaceRoot: string;
    FCachePath: string;
    FLegacyPath: string;
    FMigrateLegacy: Boolean; // Loaded from the legacy file; delete it after saving
    FFiles: TDictionary<string, TCacheEntry>;
    FOverrides: TDictionary<string, TEncodingId>; // normalized pattern -> encoding
    // In-memory changes since the last save (True = set, False = removed). Only
    // these are re-applied on top of the disk state, so entries removed on disk
    // or in memory are never resurrected.
    FPendingFiles: TDictionary<string, Boolean>;
    FPendingOverrides: TDictionary<string, Boolean>;
    // State of the sidecar file when it was last read or written
    FDiskExists: Boolean;
    FDiskWriteTime: Int64;
    FDiskSize: Int64;
    FParent: TEncodingCache;
    procedure LoadInitial;
    procedure ReloadFromDisk;
    procedure RecordDiskStamp;
    function ReadSidecar(const APath: string; AFiles: TDictionary<string, TCacheEntry>;
      AOverrides: TDictionary<string, TEncodingId>): Boolean;
    procedure ParseFilesInto(AFilesObj: TJSONObject;
      ATarget: TDictionary<string, TCacheEntry>);
    procedure ParseOverridesInto(AOverridesObj: TJSONObject;
      ATarget: TDictionary<string, TEncodingId>);
    function BuildJson: TJSONObject;
    function IsDirty: Boolean;
    function NormalizeRelative(const ARelativePath: string): string;
    function TryMatchOwnPattern(const ARelativePath: string;
      out AEncodingId: TEncodingId): Boolean;
  public
    constructor Create(const AWorkspaceRoot: string);
    destructor Destroy; override;
    /// <summary>
    ///   Normalizes an override pattern. Patterns without '/' match the file
    ///   name ('*.pas'; '.pas' and 'pas' are accepted as extensions). Patterns
    ///   with '/' match the path relative to the sidecar directory and support
    ///   '*' and '?' within one folder and '**' for any number of folders.
    ///   Raises EInvalidOverridePattern for anything else.
    /// </summary>
    class function NormalizePattern(const APattern: string): string; static;
    /// <summary>
    ///   True if AFileName is a sidecar file (current or legacy) or one of the
    ///   transient lock/temp files written next to it.
    /// </summary>
    class function IsSidecarFileName(const AFileName: string): Boolean; static;
    property WorkspaceRoot: string read FWorkspaceRoot;
    property CachePath: string read FCachePath;
    /// <summary>
    ///   Cache of the enclosing sidecar directory, consulted when no pattern of
    ///   this cache matches. Not owned; maintained by TCacheManager.
    /// </summary>
    property Parent: TEncodingCache read FParent write FParent;
    /// <summary>
    ///   Writes pending changes to disk, merged on top of the current disk
    ///   state so concurrent and manual edits are kept.
    /// </summary>
    procedure Save;
    /// <summary>Reloads the sidecar if it was changed on disk since it was last read or written.</summary>
    procedure ReloadIfChanged;
    /// <summary>Retrieves a cache entry for a relative path. Returns False if not found.</summary>
    function TryGet(const ARelativePath: string; out AEntry: TCacheEntry): Boolean;
    /// <summary>Sets or updates an entry. Sidecar files themselves are never cached.</summary>
    procedure Put(const ARelativePath: string; const AEntry: TCacheEntry);
    /// <summary>Removes an entry. Used e.g. when a file has been deleted.</summary>
    procedure Remove(const ARelativePath: string);
    /// <summary>
    ///   Finds the pattern override for a path relative to this sidecar. The
    ///   most specific matching pattern of this sidecar wins; if none matches,
    ///   the parent sidecars are consulted.
    /// </summary>
    function TryGetPatternOverride(const ARelativePath: string;
      out AEncodingId: TEncodingId): Boolean;
    /// <summary>Looks up an exact pattern in this sidecar only.</summary>
    function TryGetOwnPatternOverride(const APattern: string;
      out AEncodingId: TEncodingId): Boolean;
    /// <summary>Sets a pattern override in this sidecar.</summary>
    procedure SetPatternOverride(const APattern: string; AEncodingId: TEncodingId);
    /// <summary>Removes a pattern override from this sidecar. Returns False if it was not present.</summary>
    function RemovePatternOverride(const APattern: string): Boolean;
    function PatternOverrideCount: Integer;
  end;

implementation

uses
  System.Classes,
  System.IOUtils,
  System.DateUtils,
  Winapi.Windows,
  Encoding.Workspace,
  FileIO.Atomic,
  MCP.Logging;

function TryGetFileStamp(const APath: string; out AWriteTime, ASize: Int64): Boolean;
var
  LData: TWin32FileAttributeData;
begin
  AWriteTime := 0;
  ASize := 0;
  Result := GetFileAttributesEx(PChar(APath), GetFileExInfoStandard, @LData);
  if Result then
  begin
    AWriteTime := (Int64(LData.ftLastWriteTime.dwHighDateTime) shl 32) or
      LData.ftLastWriteTime.dwLowDateTime;
    ASize := (Int64(LData.nFileSizeHigh) shl 32) or LData.nFileSizeLow;
  end;
end;

// Wildcard match of a single path segment: '*' = any characters, '?' = one.
function MatchSegment(const APattern, AText: string): Boolean;
var
  LP, LT, LStar, LMark: Integer;
begin
  LP := 1;
  LT := 1;
  LStar := 0;
  LMark := 0;
  while LT <= Length(AText) do
  begin
    if (LP <= Length(APattern)) and ((APattern[LP] = '?') or (APattern[LP] = AText[LT])) then
    begin
      Inc(LP);
      Inc(LT);
    end
    else if (LP <= Length(APattern)) and (APattern[LP] = '*') then
    begin
      LStar := LP;
      LMark := LT;
      Inc(LP);
    end
    else if LStar > 0 then
    begin
      LP := LStar + 1;
      Inc(LMark);
      LT := LMark;
    end
    else
      Exit(False);
  end;
  while (LP <= Length(APattern)) and (APattern[LP] = '*') do
    Inc(LP);
  Result := LP > Length(APattern);
end;

// Matches path segments where a '**' segment spans zero or more segments.
// A trailing '**' must cover at least one segment, so 'src/**' matches files
// below src but not a file named 'src' itself.
function MatchSegments(const APattern, AText: TArray<string>;
  APatIndex, ATextIndex: Integer): Boolean;
var
  I: Integer;
begin
  while APatIndex < Length(APattern) do
  begin
    if APattern[APatIndex] = '**' then
    begin
      if APatIndex = High(APattern) then
        Exit(ATextIndex < Length(AText));
      for I := ATextIndex to Length(AText) do
        if MatchSegments(APattern, AText, APatIndex + 1, I) then
          Exit(True);
      Exit(False);
    end;
    if (ATextIndex >= Length(AText)) or
       not MatchSegment(APattern[APatIndex], AText[ATextIndex]) then
      Exit(False);
    Inc(APatIndex);
    Inc(ATextIndex);
  end;
  Result := ATextIndex = Length(AText);
end;

// Path patterns beat file-name patterns; a longer pattern beats a shorter one;
// ties are broken alphabetically so the result is deterministic.
function IsMoreSpecific(const ACandidate, ACurrent: string): Boolean;
var
  LCandidateIsPath, LCurrentIsPath: Boolean;
begin
  if ACurrent = '' then
    Exit(True);
  LCandidateIsPath := ACandidate.Contains('/');
  LCurrentIsPath := ACurrent.Contains('/');
  if LCandidateIsPath <> LCurrentIsPath then
    Exit(LCandidateIsPath);
  if Length(ACandidate) <> Length(ACurrent) then
    Exit(Length(ACandidate) > Length(ACurrent));
  Result := CompareStr(ACandidate, ACurrent) < 0;
end;

{ TEncodingCache }

constructor TEncodingCache.Create(const AWorkspaceRoot: string);
begin
  inherited Create;
  FWorkspaceRoot := AWorkspaceRoot;
  FCachePath := TPath.Combine(AWorkspaceRoot, CACHE_FILE_NAME);
  FLegacyPath := TPath.Combine(AWorkspaceRoot, LEGACY_CACHE_FILE_NAME);
  FFiles := TDictionary<string, TCacheEntry>.Create;
  FOverrides := TDictionary<string, TEncodingId>.Create;
  FPendingFiles := TDictionary<string, Boolean>.Create;
  FPendingOverrides := TDictionary<string, Boolean>.Create;
  LoadInitial;
end;

destructor TEncodingCache.Destroy;
begin
  if IsDirty then
  begin
    try
      Save;
    except
      on E: Exception do
        TLog.Warning('Failed to save cache on destroy: %s', [E.Message]);
    end;
  end;
  FPendingOverrides.Free;
  FPendingFiles.Free;
  FFiles.Free;
  FOverrides.Free;
  inherited;
end;

class function TEncodingCache.NormalizePattern(const APattern: string): string;
const
  UNSUPPORTED_CHARS: array[0..4] of Char = ('[', ']', '{', '}', '!');
var
  LPat, LSegment: string;
  LChar: Char;
begin
  LPat := APattern.Trim.ToLower.Replace('\', '/');
  if LPat = '' then
    raise EInvalidOverridePattern.Create('The override pattern must not be empty.');
  while LPat.StartsWith('./') do
    LPat := LPat.Substring(2);
  if LPat.StartsWith('/') or LPat.Contains(':') then
    raise EInvalidOverridePattern.CreateFmt(
      'Pattern "%s" must be relative to the workspace root, not absolute.', [APattern]);
  for LChar in UNSUPPORTED_CHARS do
    if LPat.Contains(LChar) then
      raise EInvalidOverridePattern.CreateFmt(
        'Pattern "%s" uses unsupported syntax "%s". Supported: "*" (any characters ' +
        'within one folder), "?" (one character) and "**" (any number of folders), ' +
        'e.g. "*.pas" or "src/**/*.dfm".', [APattern, LChar]);
  for LSegment in LPat.Split(['/']) do
  begin
    if (LSegment = '') or (LSegment = '.') or (LSegment = '..') then
      raise EInvalidOverridePattern.CreateFmt(
        'Pattern "%s" contains an empty, "." or ".." folder.', [APattern]);
    if LSegment.Contains('**') and (LSegment <> '**') then
      raise EInvalidOverridePattern.CreateFmt(
        'Pattern "%s": "**" must be a complete folder name, e.g. "src/**/*.pas".', [APattern]);
  end;
  // A leading '**/' before a file-name pattern matches the same files as the
  // file-name pattern alone ('**/*.pas' = '*.pas').
  if LPat.StartsWith('**/') and not LPat.Substring(3).Contains('/') then
    LPat := LPat.Substring(3);
  if (LPat.IndexOfAny(['*', '?', '/']) < 0) then
  begin
    // Bare extensions: '.pas' and 'pas' mean '*.pas'
    if LPat.StartsWith('.') then
      LPat := '*' + LPat
    else if not LPat.Contains('.') then
      LPat := '*.' + LPat;
  end;
  Result := LPat;
end;

class function TEncodingCache.IsSidecarFileName(const AFileName: string): Boolean;
begin
  Result := SameText(AFileName, CACHE_FILE_NAME) or
    SameText(AFileName, LEGACY_CACHE_FILE_NAME) or
    // Pre-2.1 servers used a fixed "<sidecar>.tmp" name
    SameText(AFileName, CACHE_FILE_NAME + '.tmp') or
    SameText(AFileName, LEGACY_CACHE_FILE_NAME + '.tmp') or
    (IsTransientFileName(AFileName) and
     (AFileName.StartsWith(CACHE_FILE_NAME, True) or
      AFileName.StartsWith(LEGACY_CACHE_FILE_NAME, True)));
end;

function TEncodingCache.NormalizeRelative(const ARelativePath: string): string;
begin
  Result := ARelativePath.Replace('\', '/');
end;

function TEncodingCache.IsDirty: Boolean;
begin
  Result := (FPendingFiles.Count > 0) or (FPendingOverrides.Count > 0) or FMigrateLegacy;
end;

function ReadCacheJson(const APath: string; out AObj: TJSONObject): Boolean;
var
  LJsonText: string;
  LRoot: TJSONValue;
  LVersionValue: TJSONValue;
begin
  Result := False;
  AObj := nil;
  if not TFile.Exists(APath) then
    Exit;
  try
    LJsonText := TFile.ReadAllText(APath, TEncoding.UTF8);
  except
    on E: Exception do
    begin
      TLog.Warning('Could not read cache file %s: %s', [APath, E.Message]);
      Exit;
    end;
  end;
  LRoot := TJSONObject.ParseJSONValue(LJsonText);
  if not (LRoot is TJSONObject) then
  begin
    LRoot.Free;
    TLog.Warning('Cache file %s is not a JSON object', [APath]);
    Exit;
  end;
  AObj := TJSONObject(LRoot);
  LVersionValue := AObj.GetValue('version');
  if (LVersionValue is TJSONNumber) and
     (TJSONNumber(LVersionValue).AsInt <> CACHE_VERSION) then
    TLog.Warning('Cache file version mismatch (got %d, expected %d) — proceeding anyway',
      [TJSONNumber(LVersionValue).AsInt, CACHE_VERSION]);
  Result := True;
end;

function TEncodingCache.ReadSidecar(const APath: string;
  AFiles: TDictionary<string, TCacheEntry>;
  AOverrides: TDictionary<string, TEncodingId>): Boolean;
var
  LObj: TJSONObject;
  LValue: TJSONValue;
begin
  Result := ReadCacheJson(APath, LObj);
  if not Result then
    Exit;
  try
    LValue := LObj.GetValue('files');
    if LValue is TJSONObject then
      ParseFilesInto(TJSONObject(LValue), AFiles);
    LValue := LObj.GetValue('overrides');
    if LValue is TJSONObject then
      ParseOverridesInto(TJSONObject(LValue), AOverrides);
  finally
    LObj.Free;
  end;
end;

procedure TEncodingCache.RecordDiskStamp;
begin
  FDiskExists := TryGetFileStamp(FCachePath, FDiskWriteTime, FDiskSize);
end;

procedure TEncodingCache.LoadInitial;
var
  LSourcePath, LKey: string;
begin
  LSourcePath := FCachePath;
  if TFile.Exists(FCachePath) then
  begin
    if TFile.Exists(FLegacyPath) then
      TLog.Warning('Both %s and the legacy %s exist; using %s and ignoring the legacy file',
        [FCachePath, FLegacyPath, CACHE_FILE_NAME]);
  end
  else if TFile.Exists(FLegacyPath) then
  begin
    // Migrate: load the legacy file now, write the new name on the next save
    LSourcePath := FLegacyPath;
    FMigrateLegacy := True;
    TLog.Info('Migrating legacy sidecar %s to %s', [FLegacyPath, FCachePath]);
  end;
  ReadSidecar(LSourcePath, FFiles, FOverrides);
  if FMigrateLegacy then
  begin
    // Everything loaded from the legacy file must end up in the new file
    for LKey in FFiles.Keys do
      FPendingFiles.AddOrSetValue(LKey, True);
    for LKey in FOverrides.Keys do
      FPendingOverrides.AddOrSetValue(LKey, True);
  end;
  RecordDiskStamp;
end;

procedure TEncodingCache.ReloadFromDisk;
var
  LFiles: TDictionary<string, TCacheEntry>;
  LOverrides: TDictionary<string, TEncodingId>;
  LFilePair: TPair<string, Boolean>;
begin
  LFiles := TDictionary<string, TCacheEntry>.Create;
  LOverrides := TDictionary<string, TEncodingId>.Create;
  try
    if TFile.Exists(FCachePath) and not ReadSidecar(FCachePath, LFiles, LOverrides) then
    begin
      // Unreadable sidecar: keep the in-memory state rather than dropping it
      RecordDiskStamp;
      Exit;
    end;
    for LFilePair in FPendingFiles do
      if LFilePair.Value then
        LFiles.AddOrSetValue(LFilePair.Key, FFiles[LFilePair.Key])
      else
        LFiles.Remove(LFilePair.Key);
    for LFilePair in FPendingOverrides do
      if LFilePair.Value then
        LOverrides.AddOrSetValue(LFilePair.Key, FOverrides[LFilePair.Key])
      else
        LOverrides.Remove(LFilePair.Key);
    FFiles.Free;
    FFiles := LFiles;
    LFiles := nil;
    FOverrides.Free;
    FOverrides := LOverrides;
    LOverrides := nil;
  finally
    LOverrides.Free;
    LFiles.Free;
  end;
  RecordDiskStamp;
end;

procedure TEncodingCache.ReloadIfChanged;
var
  LExists: Boolean;
  LWriteTime, LSize: Int64;
begin
  LExists := TryGetFileStamp(FCachePath, LWriteTime, LSize);
  if (LExists = FDiskExists) and
     ((not LExists) or ((LWriteTime = FDiskWriteTime) and (LSize = FDiskSize))) then
    Exit;
  TLog.Info('Sidecar %s changed on disk; reloading', [FCachePath]);
  ReloadFromDisk;
end;

procedure TEncodingCache.ParseFilesInto(AFilesObj: TJSONObject;
  ATarget: TDictionary<string, TCacheEntry>);
var
  LPair: TJSONPair;
  LEntryObj: TJSONObject;
  LEntry: TCacheEntry;
  LValue: TJSONValue;
begin
  for LPair in AFilesObj do
  begin
    if not (LPair.JsonValue is TJSONObject) then
      Continue;
    LEntryObj := TJSONObject(LPair.JsonValue);
    LEntry := Default(TCacheEntry);
    LValue := LEntryObj.GetValue('encoding');
    if LValue is TJSONString then
      LEntry.EncodingId := EncodingIdFromName(TJSONString(LValue).Value);
    LValue := LEntryObj.GetValue('hasBom');
    LEntry.HasBom := (LValue is TJSONBool) and TJSONBool(LValue).AsBoolean;
    LValue := LEntryObj.GetValue('lineEnding');
    if LValue is TJSONString then
      LEntry.LineEnding := LineEndingFromName(TJSONString(LValue).Value);
    LValue := LEntryObj.GetValue('manual');
    LEntry.Manual := (LValue is TJSONBool) and TJSONBool(LValue).AsBoolean;
    LValue := LEntryObj.GetValue('detectedAt');
    if not ((LValue is TJSONString) and
            TryISO8601ToDate(TJSONString(LValue).Value, LEntry.DetectedAt, False)) then
      LEntry.DetectedAt := 0;
    LValue := LEntryObj.GetValue('fileSize');
    if LValue is TJSONNumber then
      LEntry.FileSize := TJSONNumber(LValue).AsInt64
    else
      LEntry.FileSize := 0;
    LValue := LEntryObj.GetValue('fileTimestamp');
    if not ((LValue is TJSONString) and
            TryISO8601ToDate(TJSONString(LValue).Value, LEntry.FileTimestamp, False)) then
      LEntry.FileTimestamp := 0;
    ATarget.AddOrSetValue(NormalizeRelative(LPair.JsonString.Value), LEntry);
  end;
end;

procedure TEncodingCache.ParseOverridesInto(AOverridesObj: TJSONObject;
  ATarget: TDictionary<string, TEncodingId>);
var
  LPair: TJSONPair;
  LEncoding: TEncodingId;
begin
  for LPair in AOverridesObj do
  begin
    if not (LPair.JsonValue is TJSONString) then
      Continue;
    LEncoding := EncodingIdFromName(TJSONString(LPair.JsonValue).Value);
    if LEncoding = TEncodingId.Unknown then
    begin
      TLog.Warning('Ignoring override "%s" in %s: unknown encoding "%s"',
        [LPair.JsonString.Value, FCachePath, TJSONString(LPair.JsonValue).Value]);
      Continue;
    end;
    try
      ATarget.AddOrSetValue(NormalizePattern(LPair.JsonString.Value), LEncoding);
    except
      on E: EInvalidOverridePattern do
        TLog.Warning('Ignoring override in %s: %s', [FCachePath, E.Message]);
    end;
  end;
end;

function TEncodingCache.BuildJson: TJSONObject;
var
  LFilesObj, LEntryObj, LOverridesObj: TJSONObject;
  LKeys: TArray<string>;
  LPath: string;
  LEntry: TCacheEntry;
  LPattern: string;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('version', TJSONNumber.Create(CACHE_VERSION));
    LFilesObj := TJSONObject.Create;
    Result.AddPair('files', LFilesObj);
    // Sorted keys keep the sidecar stable between saves
    LKeys := FFiles.Keys.ToArray;
    TArray.Sort<string>(LKeys);
    for LPath in LKeys do
    begin
      LEntry := FFiles[LPath];
      LEntryObj := TJSONObject.Create;
      LEntryObj.AddPair('encoding', EncodingIdName(LEntry.EncodingId));
      LEntryObj.AddPair('hasBom', TJSONBool.Create(LEntry.HasBom));
      LEntryObj.AddPair('lineEnding', LineEndingName(LEntry.LineEnding));
      if LEntry.Manual then
        LEntryObj.AddPair('manual', TJSONBool.Create(True));
      if LEntry.DetectedAt > 0 then
        LEntryObj.AddPair('detectedAt', DateToISO8601(LEntry.DetectedAt, False));
      if LEntry.FileSize > 0 then
        LEntryObj.AddPair('fileSize', TJSONNumber.Create(LEntry.FileSize));
      if LEntry.FileTimestamp > 0 then
        LEntryObj.AddPair('fileTimestamp', DateToISO8601(LEntry.FileTimestamp, False));
      LFilesObj.AddPair(LPath, LEntryObj);
    end;
    LOverridesObj := TJSONObject.Create;
    Result.AddPair('overrides', LOverridesObj);
    LKeys := FOverrides.Keys.ToArray;
    TArray.Sort<string>(LKeys);
    for LPattern in LKeys do
      LOverridesObj.AddPair(LPattern, EncodingIdName(FOverrides[LPattern]));
  except
    Result.Free;
    raise;
  end;
end;

procedure TEncodingCache.Save;
var
  LLock: TFileLock;
  LJson: TJSONObject;
  LText: string;
begin
  if not IsDirty then
    Exit;
  // The merge below reads the sidecar and writes it back; holding the lock
  // across both steps stops a concurrent instance from losing its entries.
  // On failure the pending changes are kept and retried by the next Save.
  try
    LLock := TFileLock.Create(FCachePath);
  except
    on E: EFileLockedError do
    begin
      TLog.Error('Failed to lock cache %s: %s', [FCachePath, E.Message]);
      Exit;
    end;
    on E: EOSError do
    begin
      TLog.Error('Failed to lock cache %s: %s', [FCachePath, E.Message]);
      Exit;
    end;
  end;
  try
    // Merge pending changes on top of the current disk state, so entries from
    // other instances and manual edits are kept and removals stay removed
    ReloadFromDisk;
    LJson := BuildJson;
    try
      LText := LJson.Format(2);
    finally
      LJson.Free;
    end;
    try
      WriteBytesAtomic(FCachePath, TEncoding.UTF8.GetBytes(LText));
    except
      on E: Exception do
      begin
        TLog.Error('Failed to save cache to %s: %s', [FCachePath, E.Message]);
        Exit;
      end;
    end;
    FPendingFiles.Clear;
    FPendingOverrides.Clear;
    RecordDiskStamp;
  finally
    LLock.Free;
  end;
  if FMigrateLegacy then
  begin
    FMigrateLegacy := False;
    if TFile.Exists(FLegacyPath) and not System.SysUtils.DeleteFile(FLegacyPath) then
      TLog.Warning('Migrated sidecar to %s but could not delete legacy %s: %s',
        [FCachePath, FLegacyPath, SysErrorMessage(GetLastError)]);
  end;
end;

function TEncodingCache.TryGet(const ARelativePath: string;
  out AEntry: TCacheEntry): Boolean;
begin
  Result := FFiles.TryGetValue(NormalizeRelative(ARelativePath), AEntry);
end;

procedure TEncodingCache.Put(const ARelativePath: string; const AEntry: TCacheEntry);
var
  LKey: string;
begin
  LKey := NormalizeRelative(ARelativePath);
  // Caching the sidecar itself would make every edit of it rewrite it again
  if IsSidecarFileName(TPath.GetFileName(LKey.Replace('/', PathDelim))) then
    Exit;
  FFiles.AddOrSetValue(LKey, AEntry);
  FPendingFiles.AddOrSetValue(LKey, True);
end;

procedure TEncodingCache.Remove(const ARelativePath: string);
var
  LKey: string;
begin
  LKey := NormalizeRelative(ARelativePath);
  if FFiles.ContainsKey(LKey) then
  begin
    FFiles.Remove(LKey);
    FPendingFiles.AddOrSetValue(LKey, False);
  end;
end;

function TEncodingCache.TryMatchOwnPattern(const ARelativePath: string;
  out AEncodingId: TEncodingId): Boolean;
var
  LRelative, LFileName, LPattern, LBest: string;
  LTextSegments: TArray<string>;
  LMatch: Boolean;
begin
  LRelative := NormalizeRelative(ARelativePath).ToLower;
  LTextSegments := LRelative.Split(['/']);
  if Length(LTextSegments) = 0 then
    Exit(False);
  LFileName := LTextSegments[High(LTextSegments)];
  LBest := '';
  for LPattern in FOverrides.Keys do
  begin
    if LPattern.Contains('/') then
      LMatch := MatchSegments(LPattern.Split(['/']), LTextSegments, 0, 0)
    else
      LMatch := MatchSegment(LPattern, LFileName);
    if LMatch and IsMoreSpecific(LPattern, LBest) then
      LBest := LPattern;
  end;
  Result := LBest <> '';
  if Result then
    AEncodingId := FOverrides[LBest];
end;

function TEncodingCache.TryGetPatternOverride(const ARelativePath: string;
  out AEncodingId: TEncodingId): Boolean;
var
  LAbsolute: string;
begin
  if TryMatchOwnPattern(ARelativePath, AEncodingId) then
    Exit(True);
  if FParent = nil then
    Exit(False);
  LAbsolute := TPath.Combine(FWorkspaceRoot, ARelativePath.Replace('/', PathDelim));
  Result := FParent.TryGetPatternOverride(
    MakeRelativePath(FParent.WorkspaceRoot, LAbsolute), AEncodingId);
end;

function TEncodingCache.TryGetOwnPatternOverride(const APattern: string;
  out AEncodingId: TEncodingId): Boolean;
begin
  Result := FOverrides.TryGetValue(NormalizePattern(APattern), AEncodingId);
end;

procedure TEncodingCache.SetPatternOverride(const APattern: string;
  AEncodingId: TEncodingId);
var
  LPattern: string;
begin
  LPattern := NormalizePattern(APattern);
  FOverrides.AddOrSetValue(LPattern, AEncodingId);
  FPendingOverrides.AddOrSetValue(LPattern, True);
end;

function TEncodingCache.RemovePatternOverride(const APattern: string): Boolean;
var
  LPattern: string;
begin
  LPattern := NormalizePattern(APattern);
  Result := FOverrides.ContainsKey(LPattern);
  if Result then
  begin
    FOverrides.Remove(LPattern);
    FPendingOverrides.AddOrSetValue(LPattern, False);
  end;
end;

function TEncodingCache.PatternOverrideCount: Integer;
begin
  Result := FOverrides.Count;
end;

end.
