unit dbf_export;

interface

uses
  System.SysUtils, System.Classes, Data.Win.ADODB, ActiveX,
  xsuperobject, blcksock, synsock, Data.DB, System.Generics.Collections;

type
  TFieldTypeMap = TDictionary<string, TFieldType>;

  TDataExporter = class
  private
    class procedure SendHttpChunk(Socket: TTCPBlockSocket; const Data: string); static;
    class function GetSafeSelectSQL(Connection: TADOConnection;
      const TableName: string; var FieldTypes: TFieldTypeMap): string; static;
  public
    class procedure ExportTableToSocket(const ConnStr, TableName: string; Socket: TTCPBlockSocket);
  end;

implementation

uses
  Log4D, System.Variants;


{ Вспомогательный метод для отправки HTTP-чанка в UTF-8 }
class procedure TDataExporter.SendHttpChunk(Socket: TTCPBlockSocket; const Data: string);
var
  Buffer: TBytes;
  HexLen: string;
begin
  if Data = '' then
  begin
    Socket.SendString('0'#13#10#13#10);
    Exit;
  end;

  // Конвертируем строку в UTF-8 байты для точного подсчета размера
  Buffer := TEncoding.UTF8.GetBytes(Data);
  HexLen := IntToHex(Length(Buffer), 1);

  Socket.SendString(HexLen + #13#10);
  Socket.SendBuffer(Pointer(Buffer), Length(Buffer));
  Socket.SendString(#13#10);
end;

class function TDataExporter.GetSafeSelectSQL(Connection: TADOConnection;
  const TableName: string; var FieldTypes: TFieldTypeMap): string;
var
  Schema: TADODataSet;
  I: Integer;
  FName: string;
begin
  Result := '';
  Schema := TADODataSet.Create(nil);
  try
    Schema.Connection := Connection;
    // Запрашиваем пустой набор данных только для получения структуры
    Schema.CommandText := 'SELECT * FROM ' + TableName + ' WHERE .F.';
    Schema.Open;

    for I := 0 to Schema.FieldCount - 1 do
    begin
      FName := Schema.Fields[I].FieldName;

      FieldTypes.AddOrSetValue(LowerCase(FName), Schema.Fields[I].DataType);

      if i > 0 then Result := Result + ', ';

      case Schema.Fields[I].DataType of
        // Числовые поля защищаем от "звездочек" (переполнения)
        ftInteger, ftSmallint, ftWord, ftFloat, ftCurrency, ftBCD:
          Result := Result + Format('VAL(STR(%s, 20, 6)) AS %s', [FName, FName]);
        // DTOS: "YYYYMMDD"
        ftDate:
          Result := Result + Format('DTOS(%s) AS %s', [FName, FName]);
        // TTOC(f, 1): "YYYYMMDDHHMMSS"
        ftDateTime:
          Result := Result + Format('TTOC(%s, 1) AS %s', [FName, FName]);
        // Остальные (Memo, Date и т.д.) берем как есть
        else
          Result := Result + FName;
      end;
    end;
    Result := 'SELECT ' + Result + ' FROM ' + TableName;
  finally
    Schema.Free;
  end;
end;

class procedure TDataExporter.ExportTableToSocket(const ConnStr, TableName: string; Socket: TTCPBlockSocket);
var
  Connection: TADOConnection;
  Query: TADOQuery;
  XSO: ISuperObject;
  ChunkBuffer: TStringBuilder;
  I: Integer;
  RecNo: Integer;
  IsFirstRow: Boolean;
  Logger: TLogLogger;
  FName: string;
  FieldTypes: TFieldTypeMap;
  FieldNames: TStringList;
  OriginalType: TFieldType;
  S: string;
const
  CHUNK_THRESHOLD = 32768; // 32 КБ
begin
  Logger := TLogLogger.GetLogger(ClassName);
  CoInitialize(nil);
  Connection := TADOConnection.Create(nil);
  Query := TADOQuery.Create(nil);
  ChunkBuffer := TStringBuilder.Create;
  FieldTypes := TFieldTypeMap.Create;
  FieldNames := TStringList.Create;;
  try
    try
      RecNo := -1;
      Connection.ConnectionString := ConnStr;
      Connection.LoginPrompt := False;
      Connection.Open;

      Connection.Execute('SET NULL OFF');
      Connection.Execute('SET DELETED ON');

      Query.Connection := Connection;
  //    Query.CursorLocation := clUseClient;
      Query.CursorLocation := clUseServer;
      Query.CursorType := ctOpenForwardOnly; // Самый быстрый и "безопасный" тип для экспорта
      Query.LockType := ltReadOnly;

      // Напоминание: если падает на Next, здесь нужен список полей с VAL(STR())
      Query.SQL.Text := GetSafeSelectSQL(Connection, TableName, FieldTypes);
      Logger.Debug('Exec query "' + Query.SQL.Text.Trim + '"');
      Query.Open;

      // Заголовки ответа
      Socket.SendString('HTTP/1.1 200 OK'#13#10 +
                        'Content-Type: application/json; charset=utf-8'#13#10 +
                        'Transfer-Encoding: chunked'#13#10 +
                        'Connection: close'#13#10#13#10);

      ChunkBuffer.Append('[');
      IsFirstRow := True;
      RecNo := 0;
      if not Query.Eof then
        for I := 0 to Query.FieldCount - 1 do
          FieldNames.Add(LowerCase(Query.Fields[I].FieldName));
      while not Query.Eof do
      begin
        Inc(RecNo);
        if not IsFirstRow then ChunkBuffer.Append(',') else IsFirstRow := False;

        // В X-SuperObject объект создается через TSuperObject.Create
        XSO := TSuperObject.Create;
        for I := 0 to Query.FieldCount - 1 do
        begin
          FName := FieldNames[I];
          // Получаем исходный тип из нашего словаря
          if not FieldTypes.TryGetValue(FName, OriginalType) then
             OriginalType := ftUnknown;

          if Query.Fields[I].IsNull then
            XSO.V[FName] := null
          else
          case OriginalType of
            ftDate:
            begin
              S := Query.Fields[I].AsString; // "YYYYMMDD"
              if (Trim(S) = '') or (S = '00000000') then
                XSO.V[FName] := null
              else
                XSO.V[FName] := Copy(S, 1, 4) + '-' + Copy(S, 5, 2) + '-' + Copy(S, 7, 2);
            end;

            ftDateTime:
            begin
              S := Query.Fields[I].AsString; // "YYYYMMDDHHMMSS"
              // Пустой DateTime в FoxPro может прийти как пустая строка или нули
              if (Trim(S) = '') or (S = '00000000000000') then
                XSO.V[FName] := null
              else
                // Собираем ISO формат: YYYY-MM-DDThh:mm:ss
                XSO.V[FName] :=
                  Copy(S, 1, 4) + '-' + Copy(S, 5, 2) + '-' + Copy(S, 7, 2) + 'T' +
                  Copy(S, 9, 2) + ':' + Copy(S, 11, 2) + ':' + Copy(S, 13, 2);
            end;
            // Время (hh:nn:ss)
            ftTime:
              XSO.V[FName] := FormatDateTime('hh:nn:ss', Query.Fields[I].AsDateTime);

            // Целые числа
            ftInteger, ftSmallint, ftWord:
              XSO.I[FName] := Query.Fields[I].AsInteger;

            // Числа с плавающей точкой / Float / Currency
            ftFloat, ftCurrency, ftBCD:
              XSO.F[FName] := Query.Fields[I].AsFloat;

            // Логические поля
            ftBoolean:
              XSO.B[FName] := Query.Fields[I].AsBoolean;

            //  Строки с обрезкой пробелов
            ftString, ftFixedChar, ftMemo:
            begin
              S := TrimRight(Query.Fields[I].AsString);
              XSO.V[FName] := S;
            end;

            // Если не распознан
            else
              XSO.V[FName] := Query.Fields[I].AsString;
          end;
        end;

        ChunkBuffer.Append(XSO.AsJSON);
        XSO := nil;

        // Отправка накопленного буфера
        if ChunkBuffer.Length >= CHUNK_THRESHOLD then
        begin
          SendHttpChunk(Socket, ChunkBuffer.ToString);
          ChunkBuffer.Clear;
        end;

        Query.Next;
      end;

      ChunkBuffer.Append(']');
      SendHttpChunk(Socket, ChunkBuffer.ToString);
      SendHttpChunk(Socket, ''); // Завершение передачи
    except
      on E: Exception do
      begin
        Logger.Fatal(Format('Stream interrupted. Table: %s, RecNo: %d, Error: %s', [TableName, RecNo, E.Message]));

        // Закрываем сокет.
        // Клиент получит исключение "Connection closed gracefully"
        // или "Incomplete chunked body".
        Socket.CloseSocket;
        Exit;
      end;
    end;

  finally
    FieldNames.Free;
    FieldTypes.Free;
    ChunkBuffer.Free;
    Query.Free;
    Connection.Free;
    CoUninitialize;
  end;
end;

end.

