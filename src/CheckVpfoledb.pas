unit CheckVpfoledb;

interface

function IsVfpOledbInstalled: Boolean;

implementation

uses
  ComObj, SysUtils, ActiveX;

function IsVfpOledbInstalled: Boolean;
var
  ClassID: TGUID;
  Unk: IUnknown;
begin
  Result := False;
  try
    // ѕытаемс€ получить GUID класса по его текстовому ProgID
    if CLSIDFromProgID('VFPOLEDB', ClassID) = S_OK then
    begin
      // ≈сли GUID найден, провер€ем, зарегистрирован ли он физически в системе
      // (запрашиваем фабрику классов без создани€ самого объекта)
      try
        Result := (CoGetClassObject(ClassID, CLSCTX_INPROC_SERVER, nil, IUnknown, Unk) = S_OK);
      finally
        Unk := nil;
      end;
    end;
  except
    Result := False;
  end;
end;

end.
