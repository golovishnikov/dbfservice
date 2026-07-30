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

uses
  Log4D;

class function TQueryHandler.ExecuteCommand(const ConnStr, JsonBody: string): string;
var
  Connection: TADOConnection;
  Command: TADOCommand;
  XSO, XParam, XErr: ISuperObject;
  I: Integer;
  P: TParameter;
  RowsAffected: Integer;
  Logger: TLogLogger;
  Msg: string;
begin
  Result := '';
  CoInitialize(nil);
    Connection := TADOConnection.Create(nil);
    Command := TADOCommand.Create(nil);
  Logger := TLogLogger.GetLogger(ClassName);
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
            // Ожидаем формат: YYYY-MM-DDThh:nn:ss
            P.DataType := ftDateTime;
            if XParam.Null['value'] <> jAssigned then
              P.Value := System.Variants.Null
            else
              P.Value := ISO8601ToDate(XParam.S['value']);
          end
          else if SameText(XParam.S['type'], 'date') then
          begin
            // Ожидается YYYY-MM-DD или YYYY-MM-DD
            P.DataType := ftDate;
            if XParam.Null['value'] <> jAssigned then
              P.Value := System.Variants.Null
            else
              P.Value := ISO8601ToDate(XParam.S['value']);
          end
          else if SameText(XParam.S['type'], 'integer') then
          begin
            P.DataType := ftInteger;
            if XParam.Null['value'] <> jAssigned then
              P.Value := 0
            else
              P.Value := XParam.I['value'];
          end
          else if SameText(XParam.S['type'], 'float') then
          begin
            P.DataType := ftFloat;
            if XParam.Null['value'] <> jAssigned then
              P.Value := 0
            else
              P.Value := XParam.F['value'];
          end
          else if SameText(XParam.S['type'], 'boolean') then
          begin
            P.DataType := ftBoolean;
            if XParam.Null['value'] <> jAssigned then
              P.Value := False
            else
              P.Value := XParam.B['value'];
          end
          else
          begin
            P.DataType := ftString;
            if XParam.Null['value'] <> jAssigned then
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
        Msg := 'Params:';
        for I := 0 to Command.Parameters.Count - 1 do
        begin
          Msg := Msg + sLineBreak +
            Command.Parameters[I].Name + ': ' + VarToStr(Command.Parameters[I].Value);
        end;
        Logger.Error(E.Message + sLineBreak + JsonBody + sLineBreak + Msg);
        XErr := SO();
        XErr.S['error'] := E.Message;
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

