unit Tests.Encoding.Heuristics;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  THeuristicsTests = class
  public
    [Test]
    procedure IsValidUtf8_Ascii;
    [Test]
    procedure IsValidUtf8_TwoByteSequence;
    [Test]
    procedure IsValidUtf8_ThreeByteSequence;
    [Test]
    procedure IsValidUtf8_Invalid_OverlongTwoByte;
    [Test]
    procedure IsValidUtf8_Invalid_LoneStartByte;
    [Test]
    procedure IsValidUtf8_Invalid_Surrogate;
    [Test]
    procedure IsValidUtf8_Invalid_Windows1252Bytes;
    [Test]
    procedure IsPureAscii_Yes;
    [Test]
    procedure IsPureAscii_No;
  end;

implementation

uses
  System.SysUtils,
  Encoding.Heuristics;

procedure THeuristicsTests.IsValidUtf8_Ascii;
begin
  Assert.IsTrue(IsValidUtf8(TBytes.Create($48, $65, $6C, $6C, $6F)));
end;

procedure THeuristicsTests.IsValidUtf8_TwoByteSequence;
begin
  // æ = U+00E6 = C3 A6 i UTF-8
  Assert.IsTrue(IsValidUtf8(TBytes.Create($C3, $A6)));
end;

procedure THeuristicsTests.IsValidUtf8_ThreeByteSequence;
begin
  // € = U+20AC = E2 82 AC
  Assert.IsTrue(IsValidUtf8(TBytes.Create($E2, $82, $AC)));
end;

procedure THeuristicsTests.IsValidUtf8_Invalid_OverlongTwoByte;
begin
  // C0 80 ville være overlong NUL - ulovligt
  Assert.IsFalse(IsValidUtf8(TBytes.Create($C0, $80)));
end;

procedure THeuristicsTests.IsValidUtf8_Invalid_LoneStartByte;
begin
  // C3 alene uden continuation byte
  Assert.IsFalse(IsValidUtf8(TBytes.Create($C3)));
end;

procedure THeuristicsTests.IsValidUtf8_Invalid_Surrogate;
begin
  // ED A0 80 = U+D800 (surrogate, ulovligt i UTF-8)
  Assert.IsFalse(IsValidUtf8(TBytes.Create($ED, $A0, $80)));
end;

procedure THeuristicsTests.IsValidUtf8_Invalid_Windows1252Bytes;
begin
  // æ i Windows-1252 (E6) er ikke gyldig UTF-8 start byte
  Assert.IsFalse(IsValidUtf8(TBytes.Create($48, $E6)));
end;

procedure THeuristicsTests.IsPureAscii_Yes;
begin
  Assert.IsTrue(IsPureAscii(TBytes.Create($48, $65, $6C, $6C, $6F)));
end;

procedure THeuristicsTests.IsPureAscii_No;
begin
  Assert.IsFalse(IsPureAscii(TBytes.Create($48, $E6)));
end;

initialization
  TDUnitX.RegisterTestFixture(THeuristicsTests);

end.
