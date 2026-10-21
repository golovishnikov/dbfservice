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
  Command: TADOQuery;
  XSO, XParam, XErr: ISuperObject;
  I: Integer;
  P: TParameter;
  RowsAffected: Integer;
  Logger: TLogLogger;
  IsInsert: Boolean;
  Msg: string;
  SQL: string;
  Arr: TArray<string>;
begin
  Result := '';
  CoInitialize(nil);
  Connection := TADOConnection.Create(nil);
  Command := TADOQuery.Create(nil);
  Logger := TLogLogger.GetLogger(ClassName);
  try
    try
      XSO := TSuperObject.Create(JsonBody);

      Connection.ConnectionString := ConnStr;
      Connection.LoginPrompt := False;
      Connection.Open;
      Connection.BeginTrans;

      try
        // Настройки FoxPro для сессии
        Connection.Execute('SET NULL OFF');
        Connection.Execute('SET DELETED ON');

        SQL := XSO.S['sql'];
        Arr := SQL.Split([' ', '(', ')', #8, #9, #10, #13], ExcludeEmpty);
        IsInsert := (Length(Arr) > 2) and SameText(Arr[0], 'INSERT');

        Command.Connection := Connection;
        Command.SQL.Text := SQL;
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

        RowsAffected := Command.ExecSQL;

        XErr := SO();
        XErr.S['status'] := 'success';
        XErr.I['rows_affected'] := RowsAffected;

        if IsInsert then
        begin
          Command.SQL.Text := 'select recno(''' + Arr[2] + ''') as row_id from ' + Arr[2] + ' where recno()=recno(''' + Arr[2] + ''')';
          Command.Parameters.Clear;
          Command.Open;
          if not Command.Eof then
            XErr.I['row_id'] := Command.Fields[0].AsInteger;
          Command.Close;
        end;
        Connection.CommitTrans;

        Result := XErr.AsJSON;
      finally
        if Connection.InTransaction then
          Connection.RollbackTrans;
      end;
    except
      on E: Exception do
      begin
        Msg := 'Params:';
        for I := 0 to Command.Parameters.Count - 1 do
        begin
          Msg := Msg + sLineBreak +
            Command.Parameters[I].Name + ': ' + VarToStr(Command.Parameters[I].Value);
        end;
        Logger.Error(E.Message + sLineBreak + JsonBody + sLineBreak + Command.SQL.Text + sLineBreak + Msg);
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

