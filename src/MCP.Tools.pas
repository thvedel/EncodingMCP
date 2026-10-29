unit MCP.Tools;

/// <summary>
///   Tool interface and registration mechanism for MCP tools.
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections;

type
  /// <summary>
  ///   An MCP tool. Each tool exposes a name, description, JSON Schema
  ///   for parameters, and an execution method.
  /// </summary>
  IMcpTool = interface
    ['{B7F6F4A8-2C19-4F4A-8D19-9E5B7C2C9A11}']
    function GetName: string;
    function GetDescription: string;
    /// <summary>
    ///   Returns a JSON Schema object describing the tool parameters.
    ///   The caller takes ownership.
    /// </summary>
    function BuildInputSchema: TJSONObject;
    /// <summary>
    ///   Executes the tool. Returns an MCP content object with
    ///   "content" array and optional "isError". The caller takes ownership.
    /// </summary>
    /// <param name="AArguments">JSON arguments (may be nil for parameterless tools).</param>
    /// <exception cref="Exception">On internal errors. Dispatcher converts to MCP error response.</exception>
    function Execute(AArguments: TJSONObject): TJSONObject;
  end;

  /// <summary>
  ///   Registry for IMcpTool instances, looked up by name.
  /// </summary>
  TToolRegistry = class
  strict private
    FTools: TDictionary<string, IMcpTool>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Register(const ATool: IMcpTool);
    function TryGet(const AName: string; out ATool: IMcpTool): Boolean;
    function Names: TArray<string>;
    /// <summary>Builds the MCP "tools/list" JSON array. The caller takes ownership.</summary>
    function BuildListJson: TJSONArray;
  end;

/// <summary>
///   Builds a standard MCP tool result with a single text block.
///   The caller takes ownership.
/// </summary>
function BuildTextResult(const AText: string; AIsError: Boolean = False): TJSONObject;

/// <summary>
///   Builds an MCP tool result where the text is a serialized JSON value
///   (typically pretty-printed JSON). The caller takes ownership.
/// </summary>
function BuildJsonTextResult(AJson: TJSONValue; AIsError: Boolean = False): TJSONObject;

/// <summary>
///   Builds the structured error object for a file in a non-text format
///   (fields path, error, format). The caller takes ownership.
/// </summary>
function BuildFormatErrorJson(const APath, AFormat, AMessage: string): TJSONObject;

type
  /// <summary>
  ///   Raised when tool arguments do not match the tool's input schema.
  /// </summary>
  EInvalidArgumentError = class(Exception);

/// <summary>
///   Validates tool arguments against the tool's input schema: rejects unknown
///   property names and values of the wrong JSON type, also inside nested
///   objects and arrays of objects. A misspelled option (e.g. "bom" instead of
///   "hasBom") would otherwise be ignored silently and change the result.
/// </summary>
/// <param name="ASchema">The tool's JSON Schema (as returned by BuildInputSchema).</param>
/// <param name="AArguments">The call arguments; nil is accepted.</param>
/// <exception cref="EInvalidArgumentError">On unknown or mistyped arguments.</exception>
procedure ValidateArguments(ASchema, AArguments: TJSONObject);

/// <summary>
///   Returns the string argument AName, or ADefault when the object is nil or
///   the value is missing, null or not a string.
/// </summary>
function GetStringArg(AArgs: TJSONObject; const AName: string;
  const ADefault: string = ''): string;

/// <summary>
///   Returns the integer argument AName, or ADefault when the object is nil or
///   the value is missing, null or not a number.
/// </summary>
function GetIntArg(AArgs: TJSONObject; const AName: string;
  ADefault: Integer = 0): Integer;

/// <summary>
///   Returns the boolean argument AName, or ADefault when the object is nil or
///   the value is missing, null or not a boolean.
/// </summary>
function GetBoolArg(AArgs: TJSONObject; const AName: string;
  ADefault: Boolean = False): Boolean;

/// <summary>True if AName is present and not null.</summary>
function HasArg(AArgs: TJSONObject; const AName: string): Boolean;

/// <summary>
///   Builds a JSON Schema property of the given type with a description.
///   The caller takes ownership.
/// </summary>
function MakeProp(const AType, ADescription: string): TJSONObject;

implementation

function GetStringArg(AArgs: TJSONObject; const AName: string;
  const ADefault: string): string;
var
  LValue: TJSONValue;
begin
  if AArgs = nil then
    Exit(ADefault);
  LValue := AArgs.GetValue(AName);
  if LValue is TJSONString then
    Result := TJSONString(LValue).Value
  else
    Result := ADefault;
end;

function GetIntArg(AArgs: TJSONObject; const AName: string;
  ADefault: Integer): Integer;
var
  LValue: TJSONValue;
begin
  if AArgs = nil then
    Exit(ADefault);
  LValue := AArgs.GetValue(AName);
  if LValue is TJSONNumber then
    Result := TJSONNumber(LValue).AsInt
  else
    Result := ADefault;
end;

function GetBoolArg(AArgs: TJSONObject; const AName: string;
  ADefault: Boolean): Boolean;
var
  LValue: TJSONValue;
begin
  if AArgs = nil then
    Exit(ADefault);
  LValue := AArgs.GetValue(AName);
  if LValue is TJSONBool then
    Result := TJSONBool(LValue).AsBoolean
  else
    Result := ADefault;
end;

function HasArg(AArgs: TJSONObject; const AName: string): Boolean;
var
  LValue: TJSONValue;
begin
  if AArgs = nil then
    Exit(False);
  LValue := AArgs.GetValue(AName);
  Result := (LValue <> nil) and not (LValue is TJSONNull);
end;

function MakeProp(const AType, ADescription: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', AType);
  Result.AddPair('description', ADescription);
end;

{ TToolRegistry }

constructor TToolRegistry.Create;
begin
  inherited;
  FTools := TDictionary<string, IMcpTool>.Create;
end;

destructor TToolRegistry.Destroy;
begin
  FTools.Free;
  inherited;
end;

procedure TToolRegistry.Register(const ATool: IMcpTool);
begin
  FTools.AddOrSetValue(ATool.GetName, ATool);
end;

function TToolRegistry.TryGet(const AName: string; out ATool: IMcpTool): Boolean;
begin
  Result := FTools.TryGetValue(AName, ATool);
end;

function TToolRegistry.Names: TArray<string>;
begin
  Result := FTools.Keys.ToArray;
end;

function TToolRegistry.BuildListJson: TJSONArray;
var
  LName: string;
  LTool: IMcpTool;
  LToolObj: TJSONObject;
begin
  Result := TJSONArray.Create;
  try
    for LName in FTools.Keys do
    begin
      LTool := FTools[LName];
      LToolObj := TJSONObject.Create;
      LToolObj.AddPair('name', LTool.GetName);
      LToolObj.AddPair('description', LTool.GetDescription);
      LToolObj.AddPair('inputSchema', LTool.BuildInputSchema);
      Result.AddElement(LToolObj);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function BuildTextResult(const AText: string; AIsError: Boolean): TJSONObject;
var
  LContent: TJSONArray;
  LBlock: TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    LContent := TJSONArray.Create;
    LBlock := TJSONObject.Create;
    LBlock.AddPair('type', 'text');
    LBlock.AddPair('text', AText);
    LContent.AddElement(LBlock);
    Result.AddPair('content', LContent);
    if AIsError then
      Result.AddPair('isError', TJSONBool.Create(True));
  except
    Result.Free;
    raise;
  end;
end;

function BuildJsonTextResult(AJson: TJSONValue; AIsError: Boolean): TJSONObject;
var
  LText: string;
begin
  if AJson = nil then
    LText := 'null'
  else
    LText := AJson.Format(2);
  AJson.Free;
  Result := BuildTextResult(LText, AIsError);
end;

function BuildFormatErrorJson(const APath, AFormat, AMessage: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('path', APath);
    Result.AddPair('error', AMessage);
    Result.AddPair('format', AFormat);
  except
    Result.Free;
    raise;
  end;
end;

procedure ValidateObject(ASchema, AObject: TJSONObject; const APrefix: string); forward;

function AllowedNames(AProps: TJSONObject): string;
var
  LPair: TJSONPair;
begin
  Result := '';
  for LPair in AProps do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + LPair.JsonString.Value;
  end;
end;

function MatchesType(AValue: TJSONValue; const AType: string): Boolean;
begin
  // TJSONNumber descends from TJSONString, so strings must exclude numbers.
  if AType = 'string' then
    Result := (AValue is TJSONString) and not (AValue is TJSONNumber)
  else if AType = 'boolean' then
    Result := AValue is TJSONBool
  else if AType = 'integer' then
    Result := (AValue is TJSONNumber) and (Frac(TJSONNumber(AValue).AsDouble) = 0)
  else if AType = 'number' then
    Result := AValue is TJSONNumber
  else if AType = 'array' then
    Result := AValue is TJSONArray
  else if AType = 'object' then
    Result := AValue is TJSONObject
  else
    Result := True;
end;

procedure ValidateValue(APropSchema: TJSONObject; AValue: TJSONValue;
  const AName: string);
var
  LType: string;
  LItems: TJSONObject;
  I: Integer;
begin
  if not APropSchema.TryGetValue<string>('type', LType) then
    Exit;
  // Clients commonly serialise omitted optional arguments as null; treat it
  // as absent, exactly like the argument readers do.
  if AValue is TJSONNull then
    Exit;
  if not MatchesType(AValue, LType) then
    raise EInvalidArgumentError.CreateFmt(
      'Argument "%s" must be of type %s, got: %s', [AName, LType, AValue.ToJSON]);
  if AValue is TJSONObject then
    ValidateObject(APropSchema, TJSONObject(AValue), AName + '.')
  else if (AValue is TJSONArray) and
          (APropSchema.GetValue('items') is TJSONObject) then
  begin
    LItems := TJSONObject(APropSchema.GetValue('items'));
    for I := 0 to TJSONArray(AValue).Count - 1 do
      ValidateValue(LItems, TJSONArray(AValue).Items[I], Format('%s[%d]', [AName, I]));
  end;
end;

procedure ValidateObject(ASchema, AObject: TJSONObject; const APrefix: string);
var
  LProps, LPropSchema: TJSONObject;
  LPair: TJSONPair;
  LName: string;
begin
  if not (ASchema.GetValue('properties') is TJSONObject) then
    Exit;
  LProps := TJSONObject(ASchema.GetValue('properties'));
  for LPair in AObject do
  begin
    LName := LPair.JsonString.Value;
    if not (LProps.GetValue(LName) is TJSONObject) then
      raise EInvalidArgumentError.CreateFmt(
        'Unknown argument "%s%s". Allowed: %s', [APrefix, LName, AllowedNames(LProps)]);
    LPropSchema := TJSONObject(LProps.GetValue(LName));
    ValidateValue(LPropSchema, LPair.JsonValue, APrefix + LName);
  end;
end;

procedure ValidateArguments(ASchema, AArguments: TJSONObject);
begin
  if (ASchema = nil) or (AArguments = nil) then
    Exit;
  ValidateObject(ASchema, AArguments, '');
end;

end.
