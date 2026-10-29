unit Tools.EditFile;

/// <summary>
///   MCP tool: edit_text_file. Performs targeted edits (search/replace or
///   line-range replacement) while preserving encoding, BOM, and line endings.
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  MCP.Tools,
  Encoding.CacheManager;

type
  TEditFileTool = class(TInterfacedObject, IMcpTool)
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
  System.Generics.Collections,
  Encoding.Types,
  Encoding.Workspace,
  FileIO.Editor,
  FileIO.Reader,
  FileIO.Writer,
  Tools.WriteFile;

{ TEditFileTool }

constructor TEditFileTool.Create(ACacheManager: TCacheManager);
begin
  inherited Create;
  FCacheManager := ACacheManager;
end;

function TEditFileTool.GetName: string;
begin
  Result := 'edit_text_file';
end;

function TEditFileTool.GetDescription: string;
begin
  Result :=
    'Edit a text file by search/replace or line-range replacement, preserving ' +
    'the file''s original encoding, BOM, and line-ending style. Use this instead ' +
    'of write_text_file when you only need to change part of a file. ' +
    'Supports two modes: (1) provide oldText+newText for search/replace, or ' +
    '(2) provide startLine+endLine+newText to replace a line range; an empty ' +
    'newText deletes the lines including their line breaks, and startLine one ' +
    'past the last line appends. Line breaks in oldText/newText are converted to ' +
    'the file''s style (the dominant style for Mixed files), so plain \n works in ' +
    'CRLF files. For multiple edits in one atomic operation, use the "edits" ' +
    'array: all line numbers in it refer to the ORIGINAL file (overlapping ranges ' +
    'are rejected), and search/replace edits are applied after the ranges. The ' +
    'response "diff" is a unified diff with one hunk per changed region; diff ' +
    'lines are separated by \n and a line break that differs from the file''s ' +
    'style is shown as [CRLF]/[LF]/[CR].';
end;

function MakeIntProp(const ADescription: string; AMinimum: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'integer');
  Result.AddPair('description', ADescription);
  Result.AddPair('minimum', TJSONNumber.Create(AMinimum));
end;

function TEditFileTool.BuildInputSchema: TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('type', 'object');
    LProps := TJSONObject.Create;

    LProps.AddPair('path', MakeProp('string',
      'Absolute path to the file to edit. The file must exist.'));

    LProps.AddPair('oldText', MakeProp('string',
      'The text to find and replace. Required for search/replace mode. ' +
      'Leave empty when using startLine/endLine range replacement.'));

    LProps.AddPair('newText', MakeProp('string',
      'The replacement text. Used in both search/replace and range modes. ' +
      'In range mode an empty newText deletes the line range completely.'));

    LProps.AddPair('startLine', MakeIntProp(
      'Optional: 1-based start line for range replacement. ' +
      'When set with endLine and oldText is empty, replaces the line range. ' +
      'One past the last line appends.', 1));

    LProps.AddPair('endLine', MakeIntProp(
      'Optional: 1-based end line (inclusive) for range replacement.', 1));

    LProps.AddPair('maxReplacements', MakeIntProp(
      'Optional: maximum number of replacements (default 1). ' +
      'Set to 0 for unlimited. When 1 and multiple matches exist, an error is raised.', 0));

    var LDryRun := TJSONObject.Create;
    LDryRun.AddPair('type', 'boolean');
    LDryRun.AddPair('description',
      'Optional: if true, compute the edit result without writing to disk. ' +
      'Useful for verifying matches before committing changes.');
    LProps.AddPair('dryRun', LDryRun);

    // Multi-edit: edits array
    var LEdits := TJSONObject.Create;
    LEdits.AddPair('type', 'array');
    LEdits.AddPair('description',
      'Optional: array of edit operations to apply atomically. ' +
      'When provided, top-level oldText/newText/startLine/endLine/maxReplacements ' +
      'are ignored. All startLine/endLine values refer to the ORIGINAL file, not to ' +
      'the result of earlier edits: range edits are applied from the end of the ' +
      'file, and overlapping ranges are rejected. Search/replace edits run afterwards ' +
      'in array order; one whose matches are created or removed by a range edit is ' +
      'rejected as ambiguous. If any edit fails, none are written. ' +
      'Each item has: oldText, newText, startLine, endLine, maxReplacements.');
    var LEditItem := TJSONObject.Create;
    LEditItem.AddPair('type', 'object');
    var LEditItemProps := TJSONObject.Create;
    LEditItemProps.AddPair('oldText', MakeProp('string', 'Text to find and replace.'));
    LEditItemProps.AddPair('newText', MakeProp('string', 'Replacement text.'));
    LEditItemProps.AddPair('startLine', MakeIntProp(
      '1-based start line in the ORIGINAL file for range mode.', 1));
    LEditItemProps.AddPair('endLine', MakeIntProp(
      '1-based end line (inclusive) in the ORIGINAL file for range mode.', 1));
    LEditItemProps.AddPair('maxReplacements', MakeIntProp(
      'Max replacements for this edit (default 1). 0 = unlimited.', 0));
    LEditItem.AddPair('properties', LEditItemProps);
    var LEditItemReq := TJSONArray.Create;
    LEditItemReq.Add('newText');
    LEditItem.AddPair('required', LEditItemReq);
    LEdits.AddPair('items', LEditItem);
    LEdits.AddPair('minItems', TJSONNumber.Create(1));
    LProps.AddPair('edits', LEdits);

    Result.AddPair('properties', LProps);
    LRequired := TJSONArray.Create;
    LRequired.Add('path');
    Result.AddPair('required', LRequired);
  except
    Result.Free;
    raise;
  end;
end;

function TEditFileTool.Execute(AArguments: TJSONObject): TJSONObject;
var
  LPath: string;
  LOptions: TEditOptions;
  LEditResult: TEditResult;
  LJson: TJSONObject;
  LEditsArr: TJSONArray;
  LEdits: TArray<TEditOptions>;
  LEditObj: TJSONObject;
  LDryRun: Boolean;
  I: Integer;
begin
  LPath := GetStringArg(AArguments, 'path', '');
  if LPath = '' then
    raise EInvalidArgumentError.Create('Missing required argument "path"');
  ValidatePathInWorkspace(LPath);

  LDryRun := GetBoolArg(AArguments, 'dryRun', False);

  // Check for multi-edit mode. An empty array is still multi-edit mode, so the
  // caller gets "Edits array must not be empty" instead of a single-edit error.
  LEditsArr := nil;
  if AArguments <> nil then
    LEditsArr := AArguments.GetValue('edits') as TJSONArray;

  if LEditsArr <> nil then
  begin
    // Multi-edit mode: parse edits array
    SetLength(LEdits, LEditsArr.Count);
    for I := 0 to LEditsArr.Count - 1 do
    begin
      LEditObj := LEditsArr.Items[I] as TJSONObject;
      LEdits[I] := MakeDefaultEditOptions;
      LEdits[I].OldText := GetStringArg(LEditObj, 'oldText', '');
      LEdits[I].NewText := GetStringArg(LEditObj, 'newText', '');
      LEdits[I].StartLine := GetIntArg(LEditObj, 'startLine', 0);
      LEdits[I].EndLine := GetIntArg(LEditObj, 'endLine', 0);
      LEdits[I].MaxReplacements := GetIntArg(LEditObj, 'maxReplacements', 1);
    end;
    try
      LEditResult := EditTextFileMulti(LPath, FCacheManager, LEdits, LDryRun);
    except
      on E: EUnsupportedCharsError do
        Exit(BuildJsonTextResult(BuildUnsupportedCharsJson(LPath, E), True));
      on E: EBinaryDfmError do
        Exit(BuildJsonTextResult(BuildFormatErrorJson(LPath, FORMAT_BINARY_DFM, E.Message), True));
    end;
  end
  else
  begin
    // Single-edit mode (backward compatible)
    LOptions := MakeDefaultEditOptions;
    LOptions.OldText := GetStringArg(AArguments, 'oldText', '');
    LOptions.NewText := GetStringArg(AArguments, 'newText', '');
    LOptions.StartLine := GetIntArg(AArguments, 'startLine', 0);
    LOptions.EndLine := GetIntArg(AArguments, 'endLine', 0);
    LOptions.MaxReplacements := GetIntArg(AArguments, 'maxReplacements', 1);
    LOptions.DryRun := LDryRun;
    try
      LEditResult := EditTextFile(LPath, FCacheManager, LOptions);
    except
      on E: EUnsupportedCharsError do
        Exit(BuildJsonTextResult(BuildUnsupportedCharsJson(LPath, E), True));
      on E: EBinaryDfmError do
        Exit(BuildJsonTextResult(BuildFormatErrorJson(LPath, FORMAT_BINARY_DFM, E.Message), True));
    end;
  end;

  LJson := TJSONObject.Create;
  try
    LJson.AddPair('path', LPath);
    LJson.AddPair('encoding', EncodingIdName(LEditResult.EncodingId));
    LJson.AddPair('hasBom', TJSONBool.Create(LEditResult.HasBom));
    LJson.AddPair('lineEnding', LineEndingName(LEditResult.LineEnding));
    LJson.AddPair('bytesWritten', TJSONNumber.Create(LEditResult.BytesWritten));
    LJson.AddPair('replacements', TJSONNumber.Create(LEditResult.Replacements));
    LJson.AddPair('changed', TJSONBool.Create(LEditResult.Changed));
    AddUpgradeAndWarningFields(LJson, LEditResult.UpgradedFrom, LEditResult.Warnings, LDryRun);
    if LEditResult.Diff <> '' then
      LJson.AddPair('diff', LEditResult.Diff);
  except
    LJson.Free;
    raise;
  end;
  Result := BuildJsonTextResult(LJson, False);
end;

end.
