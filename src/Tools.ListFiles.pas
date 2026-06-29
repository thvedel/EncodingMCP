unit Tools.ListFiles;

/// <summary>
///   MCP tool: list_files. Lists files in the workspace, optionally filtered by
///   a glob-style pattern. Returns file paths relative to workspace root.
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  MCP.Tools,
  Encoding.CacheManager;

type
  TListFilesTool = class(TInterfacedObject, IMcpTool)
  strict private
    FCacheManager: TCacheManager;
  public
    constructor Create(ACacheManager: TCacheManager);
    function GetName: string;
    function GetDescription: string;
    function BuildInputSchema: TJSONObject;
    function Execute(AArguments: TJSONObject): TJSONObject;
  end;

implementation

uses
  System.IOUtils,
  System.Types,
  System.Masks,
  Encoding.Workspace;

{ TListFilesTool }

constructor TListFilesTool.Create(ACacheManager: TCacheManager);
begin
  inherited Create;
  FCacheManager := ACacheManager;
end;

function TListFilesTool.GetName: string;
begin
  Result := 'list_files';
end;

function TListFilesTool.GetDescription: string;
begin
  Result :=
    'List files in the workspace directory, optionally filtered by a glob pattern ' +
    '(e.g. "*.pas", "src/**/*.dfm"). Returns relative paths from the workspace root. ' +
    'Useful for discovering project structure without reading file contents.';
end;

function TListFilesTool.BuildInputSchema: TJSONObject;
var
  LProps, LPath, LPattern: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('type', 'object');
    LProps := TJSONObject.Create;
    LPath := TJSONObject.Create;
    LPath.AddPair('type', 'string');
    LPath.AddPair('description',
      'Absolute path to the directory to list. Must be within the workspace.');
    LProps.AddPair('path', LPath);
    LPattern := TJSONObject.Create;
    LPattern.AddPair('type', 'string');
    LPattern.AddPair('description',
      'Optional: glob pattern to filter files (e.g. "*.pas", "*.dfm"). ' +
      'Only files matching the pattern are returned.');
    LProps.AddPair('pattern', LPattern);
    Result.AddPair('properties', LProps);
    LRequired := TJSONArray.Create;
    LRequired.Add('path');
    Result.AddPair('required', LRequired);
  except
    Result.Free;
    raise;
  end;
end;

function GetStringArg(AArgs: TJSONObject; const AName: string;
  const ADefault: string = ''): string;
var
  LValue: TJSONValue;
begin
  if AArgs = nil then Exit(ADefault);
  LValue := AArgs.GetValue(AName);
  if LValue is TJSONString then
    Result := TJSONString(LValue).Value
  else
    Result := ADefault;
end;

function MatchesPattern(const AFileName, APattern: string): Boolean;
begin
  if APattern = '' then
    Exit(True);
  Result := MatchesMask(AFileName, APattern);
end;

function TListFilesTool.Execute(AArguments: TJSONObject): TJSONObject;
var
  LPath, LPattern, LRoot: string;
  LFiles: TStringDynArray;
  LArr: TJSONArray;
  LJson: TJSONObject;
  I: Integer;
  LRelative: string;
begin
  LPath := GetStringArg(AArguments, 'path', '');
  if LPath = '' then
    raise Exception.Create('Missing required argument "path"');
  ValidatePathInWorkspace(LPath);

  if not TDirectory.Exists(LPath) then
    raise Exception.CreateFmt('Directory not found: %s', [LPath]);

  LPattern := GetStringArg(AArguments, 'pattern', '');
  LRoot := IncludeTrailingPathDelimiter(TPath.GetFullPath(LPath));

  // Get all files recursively
  LFiles := TDirectory.GetFiles(LPath, '*', TSearchOption.soAllDirectories);

  LJson := TJSONObject.Create;
  try
    LJson.AddPair('path', LPath);
    LArr := TJSONArray.Create;
    for I := 0 to Length(LFiles) - 1 do
    begin
      LRelative := Copy(LFiles[I], Length(LRoot) + 1, MaxInt);
      LRelative := LRelative.Replace('\', '/');
      if MatchesPattern(TPath.GetFileName(LFiles[I]), LPattern) then
        LArr.Add(LRelative);
    end;
    LJson.AddPair('totalFiles', TJSONNumber.Create(LArr.Count));
    LJson.AddPair('files', LArr);
  except
    LJson.Free;
    raise;
  end;
  Result := BuildJsonTextResult(LJson, False);
end;

end.
