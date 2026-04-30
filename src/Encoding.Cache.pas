unit Encoding.Cache;

/// <summary>
///   Persistent sidecar-cache der husker detekteret/manuelt sat encoding per fil.
///   Cachen lever som en JSON-fil i workspace-roden (.windsurf-encoding.json).
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
  /// <summary>Et entry i fil-cachen.</summary>
  TCacheEntry = record
    EncodingId: TEncodingId;
    HasBom: Boolean;
    LineEnding: TLineEnding;
    Manual: Boolean; // Sat via set_encoding_override
    DetectedAt: TDateTime;
  end;

  /// <summary>
  ///   In-memory + persistent cache for én workspace-rod.
  /// </summary>
  TEncodingCache = class
  strict private
    FWorkspaceRoot: string;
    FCachePath: string;
    FFiles: TDictionary<string, TCacheEntry>;
    FExtensionOverrides: TDictionary<string, TEncodingId>; // '.pas' → Windows1252
    FDirty: Boolean;
    procedure LoadFromDisk;
    procedure ParseFiles(AFilesObj: TJSONObject);
    procedure ParseOverrides(AOverridesObj: TJSONObject);
    function BuildJson: TJSONObject;
    function NormalizeRelative(const ARelativePath: string): string;
    function NormalizeExtension(const APattern: string): string;
  public
    constructor Create(const AWorkspaceRoot: string);
    destructor Destroy; override;
    property WorkspaceRoot: string read FWorkspaceRoot;
    property CachePath: string read FCachePath;
    /// <summary>Skriver ændringer til disk hvis der har været ændringer.</summary>
    procedure Save;
    /// <summary>Henter en cache-entry for en relativ sti. Returnerer False hvis ikke findes.</summary>
    function TryGet(const ARelativePath: string; out AEntry: TCacheEntry): Boolean;
    /// <summary>Sætter eller opdaterer en entry og markerer cache som dirty.</summary>
    procedure Put(const ARelativePath: string; const AEntry: TCacheEntry);
    /// <summary>Sletter en entry. Bruges fx hvis filen er slettet.</summary>
    procedure Remove(const ARelativePath: string);
    /// <summary>
    ///   Tjekker for en extension-override (fx '*.pas' → Windows-1252).
    ///   Returnerer True hvis fundet.
    /// </summary>
    function TryGetExtensionOverride(const ARelativePath: string;
      out AEncodingId: TEncodingId): Boolean;
    /// <summary>Sætter en extension-override (pattern fx '*.pas' eller '.pas').</summary>
    procedure SetExtensionOverride(const APattern: string; AEncodingId: TEncodingId);
    function ExtensionOverrideCount: Integer;
  end;

implementation

uses
  System.IOUtils,
  System.DateUtils,
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
  // Acceptér '*.pas', '**/*.pas', '.pas', 'pas'
  if LPat.StartsWith('**/') then
    LPat := LPat.Substring(3);
  if LPat.StartsWith('*') then
    LPat := LPat.Substring(1);
  if not LPat.StartsWith('.') then
    LPat := '.' + LPat;
  Result := LPat;
end;

procedure TEncodingCache.LoadFromDisk;
var
  LJsonText: string;
  LRoot: TJSONValue;
  LObj, LFilesObj, LOverridesObj: TJSONObject;
  LVersionValue: TJSONValue;
begin
  if not TFile.Exists(FCachePath) then
    Exit;
  try
    LJsonText := TFile.ReadAllText(FCachePath, TEncoding.UTF8);
  except
    on E: Exception do
    begin
      TLog.Warning('Could not read cache file %s: %s', [FCachePath, E.Message]);
      Exit;
    end;
  end;
  LRoot := TJSONObject.ParseJSONValue(LJsonText);
  if not (LRoot is TJSONObject) then
  begin
    LRoot.Free;
    TLog.Warning('Cache file %s is not a JSON object', [FCachePath]);
    Exit;
  end;
  try
    LObj := TJSONObject(LRoot);
    LVersionValue := LObj.GetValue('version');
    if (LVersionValue is TJSONNumber) and
       (TJSONNumber(LVersionValue).AsInt <> CACHE_VERSION) then
      TLog.Warning('Cache file version mismatch (got %d, expected %d) — proceeding anyway',
        [TJSONNumber(LVersionValue).AsInt, CACHE_VERSION]);
    LFilesObj := LObj.GetValue('files') as TJSONObject;
    if LFilesObj <> nil then
      ParseFiles(LFilesObj);
    LOverridesObj := LObj.GetValue('overrides') as TJSONObject;
    if LOverridesObj <> nil then
      ParseOverrides(LOverridesObj);
  finally
    LRoot.Free;
  end;
end;

procedure TEncodingCache.ParseFiles(AFilesObj: TJSONObject);
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
    FFiles.AddOrSetValue(NormalizeRelative(LPair.JsonString.Value), LEntry);
  end;
end;

procedure TEncodingCache.ParseOverrides(AOverridesObj: TJSONObject);
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
    FExtensionOverrides.AddOrSetValue(
      NormalizeExtension(LPair.JsonString.Value), LEncoding);
  end;
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

procedure TEncodingCache.Save;
var
  LJson: TJSONObject;
  LText: string;
begin
  if not FDirty then
    Exit;
  LJson := BuildJson;
  try
    LText := LJson.Format(2);
  finally
    LJson.Free;
  end;
  try
    TFile.WriteAllText(FCachePath, LText, TEncoding.UTF8);
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
