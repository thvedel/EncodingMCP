unit Encoding.Cache;

/// <summary>
///   Persistent sidecar cache that remembers detected/manually set encoding per file.
///   The cache lives as a JSON file in the workspace root (.windsurf-encoding.json).
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  Encoding.Types;

const
  CACHE_FILE_NAME = '.windsurf-encoding.json';
  CACHE_VERSION = 1;

type
  /// <summary>A single entry in the file cache.</summary>
  TCacheEntry = record
    EncodingId: TEncodingId;
    HasBom: Boolean;
    LineEnding: TLineEnding;
    Manual: Boolean; // Set via set_encoding_override
    DetectedAt: TDateTime;
  end;

  /// <summary>
  ///   In-memory + persistent cache for a single workspace root.
  /// </summary>
  TEncodingCache = class
  strict private
    FWorkspaceRoot: string;
    FCachePath: string;
    FFiles: TDictionary<string, TCacheEntry>;
    FExtensionOverrides: TDictionary<string, TEncodingId>; // '.pas' → Windows-1252
    FDirty: Boolean;
    procedure LoadFromDisk;
    procedure MergeFromDisk;
    procedure ParseFilesInto(AFilesObj: TJSONObject;
      ATarget: TDictionary<string, TCacheEntry>);
    procedure ParseOverridesInto(AOverridesObj: TJSONObject;
      ATarget: TDictionary<string, TEncodingId>);
    procedure ParseFiles(AFilesObj: TJSONObject);
    procedure ParseOverrides(AOverridesObj: TJSONObject);
    function BuildJson: TJSONObject;
    procedure AtomicWriteText(const APath, AText: string);
    function NormalizeRelative(const ARelativePath: string): string;
    function NormalizeExtension(const APattern: string): string;
  public
    constructor Create(const AWorkspaceRoot: string);
    destructor Destroy; override;
    property WorkspaceRoot: string read FWorkspaceRoot;
    property CachePath: string read FCachePath;
    /// <summary>Writes changes to disk if there have been modifications.</summary>
    procedure Save;
    /// <summary>Retrieves a cache entry for a relative path. Returns False if not found.</summary>
    function TryGet(const ARelativePath: string; out AEntry: TCacheEntry): Boolean;
    /// <summary>Sets or updates an entry and marks the cache as dirty.</summary>
    procedure Put(const ARelativePath: string; const AEntry: TCacheEntry);
    /// <summary>Removes an entry. Used e.g. when a file has been deleted.</summary>
    procedure Remove(const ARelativePath: string);
    /// <summary>
    ///   Checks for an extension override (e.g. '*.pas' → Windows-1252).
    ///   Returns True if found.
    /// </summary>
    function TryGetExtensionOverride(const ARelativePath: string;
      out AEncodingId: TEncodingId): Boolean;
    /// <summary>Sets an extension override (pattern e.g. '*.pas' or '.pas').</summary>
    procedure SetExtensionOverride(const APattern: string; AEncodingId: TEncodingId);
    function ExtensionOverrideCount: Integer;
  end;

implementation

uses
  System.Classes,
  System.IOUtils,
  System.DateUtils,
  Winapi.Windows,
  MCP.Logging;

{ TEncodingCache }

constructor TEncodingCache.Create(const AWorkspaceRoot: string);
begin
  inherited Create;
  FWorkspaceRoot := AWorkspaceRoot;
  FCachePath := TPath.Combine(AWorkspaceRoot, CACHE_FILE_NAME);
  FFiles := TDictionary<string, TCacheEntry>.Create;
  FExtensionOverrides := TDictionary<string, TEncodingId>.Create;
  FDirty := False;
  LoadFromDisk;
end;

destructor TEncodingCache.Destroy;
begin
  if FDirty then
  begin
    try
      Save;
    except
      on E: Exception do
        TLog.Warning('Failed to save cache on destroy: %s', [E.Message]);
    end;
  end;
  FFiles.Free;
  FExtensionOverrides.Free;
  inherited;
end;

function TEncodingCache.NormalizeRelative(const ARelativePath: string): string;
begin
  Result := ARelativePath.Replace('\', '/');
end;

function TEncodingCache.NormalizeExtension(const APattern: string): string;
var
  LPat: string;
begin
  LPat := APattern.ToLower.Trim;
  // Accept '*.pas', '**/*.pas', '.pas', 'pas'
  if LPat.StartsWith('**/') then
    LPat := LPat.Substring(3);
  if LPat.StartsWith('*') then
    LPat := LPat.Substring(1);
  if not LPat.StartsWith('.') then
    LPat := '.' + LPat;
  Result := LPat;
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

procedure TEncodingCache.LoadFromDisk;
var
  LObj, LFilesObj, LOverridesObj: TJSONObject;
begin
  if not ReadCacheJson(FCachePath, LObj) then
    Exit;
  try
    LFilesObj := LObj.GetValue('files') as TJSONObject;
    if LFilesObj <> nil then
      ParseFiles(LFilesObj);
    LOverridesObj := LObj.GetValue('overrides') as TJSONObject;
    if LOverridesObj <> nil then
      ParseOverrides(LOverridesObj);
  finally
    LObj.Free;
  end;
end;

procedure TEncodingCache.MergeFromDisk;
var
  LObj, LFilesObj, LOverridesObj: TJSONObject;
  LDiskFiles: TDictionary<string, TCacheEntry>;
  LDiskOverrides: TDictionary<string, TEncodingId>;
  LPath: string;
  LEntry: TCacheEntry;
  LExt: string;
  LEncId: TEncodingId;
begin
  if not ReadCacheJson(FCachePath, LObj) then
    Exit;
  LDiskFiles := TDictionary<string, TCacheEntry>.Create;
  LDiskOverrides := TDictionary<string, TEncodingId>.Create;
  try
    LFilesObj := LObj.GetValue('files') as TJSONObject;
    if LFilesObj <> nil then
      ParseFilesInto(LFilesObj, LDiskFiles);
    LOverridesObj := LObj.GetValue('overrides') as TJSONObject;
    if LOverridesObj <> nil then
      ParseOverridesInto(LOverridesObj, LDiskOverrides);
    // Merge: disk entries not present in-memory are added.
    // In-memory entries that are newer (or dirty) are preserved.
    for LPath in LDiskFiles.Keys do
    begin
      if not FFiles.ContainsKey(LPath) then
      begin
        LEntry := LDiskFiles[LPath];
        FFiles.Add(LPath, LEntry);
      end;
    end;
    for LExt in LDiskOverrides.Keys do
    begin
      if not FExtensionOverrides.ContainsKey(LExt) then
      begin
        LEncId := LDiskOverrides[LExt];
        FExtensionOverrides.Add(LExt, LEncId);
      end;
    end;
  finally
    LDiskOverrides.Free;
    LDiskFiles.Free;
    LObj.Free;
  end;
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
    if LValue is TJSONString then
    begin
      try
        LEntry.DetectedAt := ISO8601ToDate(TJSONString(LValue).Value, False);
      except
        LEntry.DetectedAt := 0;
      end;
    end;
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
      Continue;
    ATarget.AddOrSetValue(
      NormalizeExtension(LPair.JsonString.Value), LEncoding);
  end;
end;

procedure TEncodingCache.ParseFiles(AFilesObj: TJSONObject);
begin
  ParseFilesInto(AFilesObj, FFiles);
end;

procedure TEncodingCache.ParseOverrides(AOverridesObj: TJSONObject);
begin
  ParseOverridesInto(AOverridesObj, FExtensionOverrides);
end;

function TEncodingCache.BuildJson: TJSONObject;
var
  LFilesObj, LEntryObj, LOverridesObj: TJSONObject;
  LPath: string;
  LEntry: TCacheEntry;
  LExt: string;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('version', TJSONNumber.Create(CACHE_VERSION));
    LFilesObj := TJSONObject.Create;
    Result.AddPair('files', LFilesObj);
    for LPath in FFiles.Keys do
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
      LFilesObj.AddPair(LPath, LEntryObj);
    end;
    LOverridesObj := TJSONObject.Create;
    Result.AddPair('overrides', LOverridesObj);
    for LExt in FExtensionOverrides.Keys do
      LOverridesObj.AddPair('*' + LExt, EncodingIdName(FExtensionOverrides[LExt]));
  except
    Result.Free;
    raise;
  end;
end;

procedure TEncodingCache.AtomicWriteText(const APath, AText: string);
var
  LTempPath: string;
  LBytes: TBytes;
  LStream: TFileStream;
begin
  LTempPath := APath + '.tmp';
  // Write UTF-8 content to temp file
  LBytes := TEncoding.UTF8.GetBytes(AText);
  LStream := TFileStream.Create(LTempPath, fmCreate);
  try
    if Length(LBytes) > 0 then
      LStream.WriteBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
  // Atomic rename (overwrites existing)
  if not MoveFileEx(PChar(LTempPath), PChar(APath),
       MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
  begin
    // Fallback: delete + rename if MoveFileEx fails (e.g. due to antivirus)
    TLog.Warning('MoveFileEx failed for cache, trying fallback: %s',
      [SysErrorMessage(GetLastError)]);
    if TFile.Exists(APath) then
      TFile.Delete(APath);
    TFile.Move(LTempPath, APath);
  end;
end;

procedure TEncodingCache.Save;
var
  LJson: TJSONObject;
  LText: string;
begin
  if not FDirty then
    Exit;
  // Re-read and merge data from disk before writing,
  // so we don't overwrite entries from other instances
  MergeFromDisk;
  LJson := BuildJson;
  try
    LText := LJson.Format(2);
  finally
    LJson.Free;
  end;
  try
    AtomicWriteText(FCachePath, LText);
    FDirty := False;
  except
    on E: Exception do
      TLog.Error('Failed to save cache to %s: %s', [FCachePath, E.Message]);
  end;
end;

function TEncodingCache.TryGet(const ARelativePath: string;
  out AEntry: TCacheEntry): Boolean;
begin
  Result := FFiles.TryGetValue(NormalizeRelative(ARelativePath), AEntry);
end;

procedure TEncodingCache.Put(const ARelativePath: string; const AEntry: TCacheEntry);
begin
  FFiles.AddOrSetValue(NormalizeRelative(ARelativePath), AEntry);
  FDirty := True;
end;

procedure TEncodingCache.Remove(const ARelativePath: string);
begin
  if FFiles.ContainsKey(NormalizeRelative(ARelativePath)) then
  begin
    FFiles.Remove(NormalizeRelative(ARelativePath));
    FDirty := True;
  end;
end;

function TEncodingCache.TryGetExtensionOverride(const ARelativePath: string;
  out AEncodingId: TEncodingId): Boolean;
var
  LExt: string;
begin
  LExt := TPath.GetExtension(ARelativePath).ToLower;
  if LExt = '' then
    Exit(False);
  Result := FExtensionOverrides.TryGetValue(LExt, AEncodingId);
end;

procedure TEncodingCache.SetExtensionOverride(const APattern: string;
  AEncodingId: TEncodingId);
begin
  FExtensionOverrides.AddOrSetValue(NormalizeExtension(APattern), AEncodingId);
  FDirty := True;
end;

function TEncodingCache.ExtensionOverrideCount: Integer;
begin
  Result := FExtensionOverrides.Count;
end;

end.
