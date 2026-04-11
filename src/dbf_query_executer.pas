unit dbf_query_executer;

interface

uses
  System.SysUtils, System.Classes, Data.Win.ADODB, ActiveX,
  XSuperObject, System.Variants, Data.DB, System.DateUtils;

type
  TQueryHandler = class
  public
    class function ExecuteCommand(const ConnStr, JsonBody: string): string;
  end;

implementation

class function TQueryHandler.ExecuteCommand(const ConnStr, JsonBody: string): string;
var
  Connection: TADOConnection;
  Command: TADOCommand;
  XSO, XParam, XErr: ISuperObject;
  I: Integer;
  P: TParameter;
  RowsAffected: Integer;
begin
  Result := '';
  CoInitialize(nil);
  Connection := TADOConnection.Create(nil);
  Command := TADOCommand.Create(nil);
  try
    try
      XSO := TSuperObject.Create(JsonBody);

      Connection.ConnectionString := ConnStr;
      Connection.LoginPrompt := False;
      Connection.Open;

      // Настройки FoxPro для сессии
      Connection.Execute('SET NULL OFF');
      Connection.Execute('SET DELETED ON');

      Command.Connection := Connection;
      Command.CommandText := XSO.S['sql'];
      Command.Parameters.Clear;

      // Обработка параметров
      if XSO.Contains('params') then
      begin
        for I := 0 to XSO.A['params'].Length - 1 do
        begin
          XParam := XSO.A['params'].O[I];
          P := Command.Parameters.AddParameter;

          // Важно: в VFPOLEDB параметры позиционные (по порядку знаков '?')
          P.Name := 'p' + IntToStr(I);

          // Приведение типов из JSON в ADO
          if SameText(XParam.S['type'], 'datetime') then
          begin
            // Ожидаем ISO формат: YYYY-MM-DDThh:nn:ss
            P.DataType := ftDateTime;
            if XParam.V['value'] = Null then
              P.Value := 0
            else
              P.Value := ISO8601ToDate(XParam.S['value']);
          end
          else if SameText(XParam.S['type'], 'date') then
          begin
            P.DataType := ftDate;
            if XParam.V['value'] = Null then
              P.Value := 0
            else
              P.Value := ISO8601ToDate(XParam.S['value']);
          end
          else if SameText(XParam.S['type'], 'integer') then
          begin
            P.DataType := ftInteger;
            if XParam.V['value'] = Null then
              P.Value := 0
            else
              P.Value := XParam.I['value'];
          end
          else if SameText(XParam.S['type'], 'float') then
          begin
            P.DataType := ftFloat;
            if XParam.V['value'] = Null then
              P.Value := 0
            else
              P.Value := XParam.F['value'];
          end
          else
          begin
            P.DataType := ftString;
            if XParam.V['value'] = Null then
              P.Value := ''
            else
              P.Value := XParam.S['value'];
          end;
        end;
      end;

      Command.Execute(RowsAffected, EmptyParam);

      Result := '{"status":"success", "rows_affected":' + IntToStr(RowsAffected) + '}';

    except
      on E: Exception do
      begin
        XErr := SO();
        XErr.S['status'] := 'error';
        XErr.S['message'] := E.Message;
        Result := XErr.AsJSON;
      end;
    end;
  finally
    Command.Free;
    Connection.Free;
    CoUninitialize;
  end;
end;

end.

