unit MCP.Server;

/// <summary>
///   MCP-server der dispatcher JSON-RPC requests til tool-handlers og
///   håndterer MCP-lifecycle (initialize, tools/list, tools/call).
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  MCP.Stdio,
  MCP.Protocol,
  MCP.Tools;

const
  MCP_PROTOCOL_VERSION = '2024-11-05';
  SERVER_NAME = 'encoding-bridge';
  SERVER_VERSION = '0.1.0';

type
  /// <summary>
  ///   MCP-server. Læser linjer fra stdin, dispatcher til tools, skriver svar til stdout.
  /// </summary>
  TMcpServer = class
  strict private
    FTransport: TStdioTransport;
    FRegistry: TToolRegistry;
    FInitialized: Boolean;
    function HandleInitialize(AParams: TJSONValue): TJSONValue;
    function HandleToolsList: TJSONValue;
    function HandleToolsCall(AParams: TJSONValue): TJSONValue;
    procedure DispatchRequest(ARequest: TJsonRpcRequest);
  public
    constructor Create(ARegistry: TToolRegistry);
    destructor Destroy; override;
    /// <summary>
    ///   Hovedløkken. Returnerer når stdin lukkes.
    /// </summary>
    procedure Run;
  end;

implementation

uses
  MCP.Logging;

{ TMcpServer }

constructor TMcpServer.Create(ARegistry: TToolRegistry);
begin
  inherited Create;
  FTransport := TStdioTransport.Create;
  FRegistry := ARegistry;
  FInitialized := False;
end;

destructor TMcpServer.Destroy;
begin
  FTransport.Free;
  inherited;
end;

function TMcpServer.HandleInitialize(AParams: TJSONValue): TJSONValue;
var
  LResult, LCapabilities, LServerInfo, LToolsCap: TJSONObject;
begin
  LResult := TJSONObject.Create;
  try
    LResult.AddPair('protocolVersion', MCP_PROTOCOL_VERSION);
    LCapabilities := TJSONObject.Create;
    LToolsCap := TJSONObject.Create;
    LCapabilities.AddPair('tools', LToolsCap);
    LResult.AddPair('capabilities', LCapabilities);
    LServerInfo := TJSONObject.Create;
    LServerInfo.AddPair('name', SERVER_NAME);
    LServerInfo.AddPair('version', SERVER_VERSION);
    LResult.AddPair('serverInfo', LServerInfo);
    Result := LResult;
  except
    LResult.Free;
    raise;
  end;
end;

function TMcpServer.HandleToolsList: TJSONValue;
var
  LResult: TJSONObject;
begin
  LResult := TJSONObject.Create;
  try
    LResult.AddPair('tools', FRegistry.BuildListJson);
    Result := LResult;
  except
    LResult.Free;
    raise;
  end;
end;

function TMcpServer.HandleToolsCall(AParams: TJSONValue): TJSONValue;
var
  LParamsObj, LArguments: TJSONObject;
  LNameValue, LArgsValue: TJSONValue;
  LToolName: string;
  LTool: IMcpTool;
begin
  if not (AParams is TJSONObject) then
    raise EJsonRpcError.Create(Ord(TJsonRpcErrorCode.InvalidParams),
      'tools/call requires object params');
  LParamsObj := TJSONObject(AParams);
  LNameValue := LParamsObj.GetValue('name');
  if not (LNameValue is TJSONString) then
    raise EJsonRpcError.Create(Ord(TJsonRpcErrorCode.InvalidParams),
      'tools/call requires "name" string');
  LToolName := TJSONString(LNameValue).Value;
  LArgsValue := LParamsObj.GetValue('arguments');
  if (LArgsValue <> nil) and not (LArgsValue is TJSONObject) then
    raise EJsonRpcError.Create(Ord(TJsonRpcErrorCode.InvalidParams),
      '"arguments" must be an object');
  LArguments := nil;
  if LArgsValue <> nil then
    LArguments := TJSONObject(LArgsValue);
  if not FRegistry.TryGet(LToolName, LTool) then
    raise EJsonRpcError.Create(Ord(TJsonRpcErrorCode.MethodNotFound),
      Format('Unknown tool "%s"', [LToolName]));
  try
    Result := LTool.Execute(LArguments);
  except
    on E: EJsonRpcError do
      raise;
    on E: Exception do
    begin
      TLog.Error('Tool "%s" failed: %s', [LToolName, E.Message]);
      // MCP-konvention: tool-fejl returneres som content med isError=true,
      // ikke som JSON-RPC error
      Result := BuildTextResult(Format('Error: %s', [E.Message]), True);
    end;
  end;
end;

procedure TMcpServer.DispatchRequest(ARequest: TJsonRpcRequest);
var
  LResultValue: TJSONValue;
  LResponseJson: string;
begin
  LResultValue := nil;
  try
    try
      if ARequest.Method = 'initialize' then
      begin
        LResultValue := HandleInitialize(ARequest.Params);
        FInitialized := True;
      end
      else if ARequest.Method = 'notifications/initialized' then
      begin
        // Notifikation, intet svar
        Exit;
      end
      else if ARequest.Method = 'tools/list' then
        LResultValue := HandleToolsList
      else if ARequest.Method = 'tools/call' then
        LResultValue := HandleToolsCall(ARequest.Params)
      else if ARequest.Method = 'ping' then
        LResultValue := TJSONObject.Create
      else if ARequest.Method = 'shutdown' then
        LResultValue := TJSONObject.Create
      else
      begin
        if not ARequest.IsNotification then
        begin
          LResponseJson := BuildJsonRpcError(ARequest.Id,
            Ord(TJsonRpcErrorCode.MethodNotFound),
            Format('Method "%s" not found', [ARequest.Method]));
          FTransport.WriteLine(LResponseJson);
        end;
        Exit;
      end;
      if not ARequest.IsNotification then
      begin
        LResponseJson := BuildJsonRpcResult(ARequest.Id, LResultValue);
        LResultValue := nil; // ejerskab overdraget til BuildJsonRpcResult
        FTransport.WriteLine(LResponseJson);
      end
      else
        FreeAndNil(LResultValue);
    except
      on E: EJsonRpcError do
      begin
        if not ARequest.IsNotification then
        begin
          LResponseJson := BuildJsonRpcError(ARequest.Id, E.Code, E.Message,
            CloneJsonValue(E.Data));
          FTransport.WriteLine(LResponseJson);
        end;
      end;
      on E: Exception do
      begin
        TLog.Error('Internal error in dispatcher: %s', [E.Message]);
        if not ARequest.IsNotification then
        begin
          LResponseJson := BuildJsonRpcError(ARequest.Id,
            Ord(TJsonRpcErrorCode.InternalError), E.Message);
          FTransport.WriteLine(LResponseJson);
        end;
      end;
    end;
  finally
    LResultValue.Free;
  end;
end;

procedure TMcpServer.Run;
var
  LLine: string;
  LRequest: TJsonRpcRequest;
  LResponseJson: string;
begin
  TLog.Info('%s %s starting (protocol %s)',
    [SERVER_NAME, SERVER_VERSION, MCP_PROTOCOL_VERSION]);
  while FTransport.TryReadLine(LLine) do
  begin
    LLine := LLine.Trim;
    if LLine = '' then
      Continue;
    LRequest := nil;
    try
      try
        LRequest := ParseJsonRpcRequest(LLine);
      except
        on E: EJsonRpcError do
        begin
          LResponseJson := BuildJsonRpcError(nil, E.Code, E.Message);
          FTransport.WriteLine(LResponseJson);
          Continue;
        end;
        on E: Exception do
        begin
          TLog.Error('Failed to parse request: %s', [E.Message]);
          Continue;
        end;
      end;
      DispatchRequest(LRequest);
    finally
      LRequest.Free;
    end;
  end;
  TLog.Info('Stdin closed, shutting down');
end;

end.
