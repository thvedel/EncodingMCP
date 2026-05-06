unit MCP.Protocol;

/// <summary>
///   JSON-RPC 2.0 data types and helper functions for MCP communication.
///   Built on System.JSON (RTL).
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON;

type
  /// <summary>
  ///   JSON-RPC 2.0 error codes.
  /// </summary>
  TJsonRpcErrorCode = (
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603
  );

  /// <summary>
  ///   An incoming JSON-RPC request or notification. Notifications have
  ///   no Id and do not expect a response.
  /// </summary>
  TJsonRpcRequest = class
  strict private
    FId: TJSONValue;
    FMethod: string;
    FParams: TJSONValue;
    FIsNotification: Boolean;
  public
    constructor Create(AId: TJSONValue; const AMethod: string; AParams: TJSONValue;
      AIsNotification: Boolean);
    destructor Destroy; override;
    property Id: TJSONValue read FId;
    property Method: string read FMethod;
    property Params: TJSONValue read FParams;
    property IsNotification: Boolean read FIsNotification;
  end;

  EJsonRpcError = class(Exception)
  strict private
    FCode: Integer;
    FData: TJSONValue;
  public
    constructor Create(ACode: Integer; const AMessage: string; AData: TJSONValue = nil);
    destructor Destroy; override;
    property Code: Integer read FCode;
    property Data: TJSONValue read FData;
  end;

/// <summary>
///   Parses a JSON-RPC request from a string. Raises EJsonRpcError on invalid
///   messages. Returns an owned TJsonRpcRequest.
/// </summary>
function ParseJsonRpcRequest(const AJson: string): TJsonRpcRequest;

/// <summary>
///   Builds a JSON-RPC success response as a JSON string. AResult is consumed (owned by result).
/// </summary>
function BuildJsonRpcResult(AId: TJSONValue; AResult: TJSONValue): string;

/// <summary>
///   Builds a JSON-RPC error response as a JSON string. AData is consumed if not nil.
/// </summary>
function BuildJsonRpcError(AId: TJSONValue; ACode: Integer; const AMessage: string;
  AData: TJSONValue = nil): string;

/// <summary>
///   Returns a cloned TJSONValue of an existing value, or nil if input is nil.
/// </summary>
function CloneJsonValue(AValue: TJSONValue): TJSONValue;

implementation

{ TJsonRpcRequest }

constructor TJsonRpcRequest.Create(AId: TJSONValue; const AMethod: string;
  AParams: TJSONValue; AIsNotification: Boolean);
begin
  inherited Create;
  FId := AId;
  FMethod := AMethod;
  FParams := AParams;
  FIsNotification := AIsNotification;
end;

destructor TJsonRpcRequest.Destroy;
begin
  FId.Free;
  FParams.Free;
  inherited;
end;

{ EJsonRpcError }

constructor EJsonRpcError.Create(ACode: Integer; const AMessage: string; AData: TJSONValue);
begin
  inherited Create(AMessage);
  FCode := ACode;
  FData := AData;
end;

destructor EJsonRpcError.Destroy;
begin
  FData.Free;
  inherited;
end;

function CloneJsonValue(AValue: TJSONValue): TJSONValue;
begin
  if AValue = nil then
    Exit(nil);
  Result := AValue.Clone as TJSONValue;
end;

function ParseJsonRpcRequest(const AJson: string): TJsonRpcRequest;
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
  LIdValue, LParamsValue, LMethodValue: TJSONValue;
  LMethod: string;
  LIsNotification: Boolean;
  LClonedId, LClonedParams: TJSONValue;
begin
  LRoot := TJSONObject.ParseJSONValue(AJson);
  if LRoot = nil then
    raise EJsonRpcError.Create(Ord(TJsonRpcErrorCode.ParseError), 'Invalid JSON');
  try
    if not (LRoot is TJSONObject) then
      raise EJsonRpcError.Create(Ord(TJsonRpcErrorCode.InvalidRequest),
        'Request must be a JSON object');
    LObj := TJSONObject(LRoot);
    LMethodValue := LObj.GetValue('method');
    if not (LMethodValue is TJSONString) then
      raise EJsonRpcError.Create(Ord(TJsonRpcErrorCode.InvalidRequest),
        'Missing or invalid "method" field');
    LMethod := TJSONString(LMethodValue).Value;
    LIdValue := LObj.GetValue('id');
    LParamsValue := LObj.GetValue('params');
    LIsNotification := LIdValue = nil;
    LClonedId := CloneJsonValue(LIdValue);
    LClonedParams := CloneJsonValue(LParamsValue);
    Result := TJsonRpcRequest.Create(LClonedId, LMethod, LClonedParams, LIsNotification);
  finally
    LRoot.Free;
  end;
end;

function BuildJsonRpcResult(AId: TJSONValue; AResult: TJSONValue): string;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('jsonrpc', '2.0');
    // AId is cloned so the caller retains ownership
    if AId <> nil then
      LObj.AddPair('id', AId.Clone as TJSONValue)
    else
      LObj.AddPair('id', TJSONNull.Create);
    if AResult <> nil then
      LObj.AddPair('result', AResult)
    else
      LObj.AddPair('result', TJSONObject.Create);
    Result := LObj.ToJSON;
  finally
    LObj.Free;
  end;
end;

function BuildJsonRpcError(AId: TJSONValue; ACode: Integer; const AMessage: string;
  AData: TJSONValue): string;
var
  LObj, LErr: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('jsonrpc', '2.0');
    // AId is cloned so the caller retains ownership
    if AId <> nil then
      LObj.AddPair('id', AId.Clone as TJSONValue)
    else
      LObj.AddPair('id', TJSONNull.Create);
    LErr := TJSONObject.Create;
    LErr.AddPair('code', TJSONNumber.Create(ACode));
    LErr.AddPair('message', AMessage);
    if AData <> nil then
      LErr.AddPair('data', AData);
    LObj.AddPair('error', LErr);
    Result := LObj.ToJSON;
  finally
    LObj.Free;
  end;
end;

end.
