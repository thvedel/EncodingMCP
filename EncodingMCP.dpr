program EncodingMCP;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MCP.Logging in 'src\MCP.Logging.pas',
  MCP.Stdio in 'src\MCP.Stdio.pas',
  MCP.Protocol in 'src\MCP.Protocol.pas',
  MCP.Tools in 'src\MCP.Tools.pas',
  MCP.Server in 'src\MCP.Server.pas',
  Encoding.Types in 'src\Encoding.Types.pas',
  Encoding.Heuristics in 'src\Encoding.Heuristics.pas',
  Encoding.Detector in 'src\Encoding.Detector.pas',
  Encoding.Workspace in 'src\Encoding.Workspace.pas',
  Encoding.Cache in 'src\Encoding.Cache.pas',
  Encoding.CacheManager in 'src\Encoding.CacheManager.pas',
  FileIO.Reader in 'src\FileIO.Reader.pas',
  FileIO.Writer in 'src\FileIO.Writer.pas',
  Tools.ReadFile in 'src\Tools.ReadFile.pas',
  Tools.WriteFile in 'src\Tools.WriteFile.pas',
  Tools.DetectEncoding in 'src\Tools.DetectEncoding.pas',
  Tools.SetOverride in 'src\Tools.SetOverride.pas',
  FileIO.Editor in 'src\FileIO.Editor.pas',
  Tools.EditFile in 'src\Tools.EditFile.pas',
  Tools.ListFiles in 'src\Tools.ListFiles.pas',
  Tools.BatchRead in 'src\Tools.BatchRead.pas',
  Tools.BatchWrite in 'src\Tools.BatchWrite.pas',
  FileIO.Atomic in 'src\FileIO.Atomic.pas';

{$R *.res}

procedure ConfigureLogging;
var
  LEnvLevel: string;
begin
  LEnvLevel := GetEnvironmentVariable('ENCODING_MCP_LOG_LEVEL').ToLower;
  if LEnvLevel = 'debug' then
    TLog.SetMinLevel(TLogLevel.Debug)
  else if LEnvLevel = 'warning' then
    TLog.SetMinLevel(TLogLevel.Warning)
  else if LEnvLevel = 'error' then
    TLog.SetMinLevel(TLogLevel.Error)
  else
    TLog.SetMinLevel(TLogLevel.Info);
end;

procedure ConfigureWorkspaceRoots;
var
  LEnv, LRoot: string;
  LParts: TArray<string>;
  I: Integer;
  LCount: Integer;
begin
  LCount := 0;
  // 1. Command line arguments (each non-switch argument is a workspace root)
  for I := 1 to ParamCount do
  begin
    LRoot := ParamStr(I);
    if (LRoot = '') or LRoot.StartsWith('-') or LRoot.StartsWith('/') then
      Continue;
    if AddWorkspaceRoot(LRoot) then
      Inc(LCount)
    else
      TLog.Warning('Ignoring workspace root (not an existing directory): %s', [LRoot]);
  end;
  // 2. ENCODING_MCP_WORKSPACE, semicolon-separated
  LEnv := GetEnvironmentVariable('ENCODING_MCP_WORKSPACE');
  if LEnv <> '' then
  begin
    LParts := LEnv.Split([';']);
    for I := 0 to High(LParts) do
    begin
      LRoot := LParts[I].Trim;
      if LRoot = '' then
        Continue;
      if AddWorkspaceRoot(LRoot) then
        Inc(LCount)
      else
        TLog.Warning('Ignoring workspace root (not an existing directory): %s', [LRoot]);
    end;
  end;
  // 3. Fall back to the workspace containing the current directory
  if LCount = 0 then
  begin
    LRoot := FindWorkspaceRoot(GetCurrentDir);
    if AddWorkspaceRoot(LRoot) then
      Inc(LCount);
  end;

  if LCount = 0 then
    TLog.Warning('No workspace root configured; all tool calls will be rejected. ' +
      'Pass a directory as an argument or set ENCODING_MCP_WORKSPACE.')
  else
    TLog.Info('Allowed workspace root(s): %s',
      [string.Join('; ', GetWorkspaceRoots)]);
end;

procedure RegisterTools(ARegistry: TToolRegistry; ACacheManager: TCacheManager);
begin
  ARegistry.Register(TReadFileTool.Create(ACacheManager));
  ARegistry.Register(TWriteFileTool.Create(ACacheManager));
  ARegistry.Register(TDetectEncodingTool.Create(ACacheManager));
  ARegistry.Register(TSetOverrideTool.Create(ACacheManager));
  ARegistry.Register(TEditFileTool.Create(ACacheManager));
  ARegistry.Register(TListFilesTool.Create(ACacheManager));
  ARegistry.Register(TBatchReadTool.Create(ACacheManager));
  ARegistry.Register(TBatchWriteTool.Create(ACacheManager));
end;

var
  LRegistry: TToolRegistry;
  LCacheManager: TCacheManager;
  LServer: TMcpServer;

begin
  {$IFDEF DEBUG}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  ConfigureLogging;
  ConfigureWorkspaceRoots;
  try
    LCacheManager := TCacheManager.Create;
    try
      LRegistry := TToolRegistry.Create;
      try
        RegisterTools(LRegistry, LCacheManager);
        LServer := TMcpServer.Create(LRegistry, LCacheManager);
        try
          LServer.Run;
        finally
          LServer.Free;
        end;
      finally
        LRegistry.Free;
      end;
    finally
      LCacheManager.Free;
    end;
  except
    on E: Exception do
    begin
      TLog.Error('Fatal: %s: %s', [E.ClassName, E.Message]);
      ExitCode := 1;
    end;
  end;
end.
