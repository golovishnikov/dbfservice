unit HttpRequestWorker;

interface

uses
  Classes, SysUtils, blcksock, synsock, Log4d, System.JSON;

type
  TWorkerThread = class(TThread)
  private
    FSocket: TTCPBlockSocket;
    FClientHandle: TSocket;
    FLogger: TLogLogger;
    procedure ProcessRequest;
    procedure SendResponse(Code: Integer; const Status, ContentType, Body: string);
  protected
    procedure Execute; override;
  public
    constructor Create(ASocketHandle: TSocket);
  end;

implementation

uses
  options, dbf_export, dbf_query_executer;

{ TWorkerThread }

constructor TWorkerThread.Create(ASocketHandle: TSocket);
begin
  inherited Create(False);
  FClientHandle := ASocketHandle;
  FreeOnTerminate := True;
  FLogger := TLogLogger.GetLogger(TWorkerThread.ClassName);
end;

procedure TWorkerThread.Execute;
begin
  FSocket := TTCPBlockSocket.Create;
  try
    try
      FSocket.Socket := FClientHandle;
      FSocket.GetRemoteSinIP; // Для логов, если нужно знать IP клиента
      ProcessRequest;
    except
      on E: Exception do
        FLogger.Fatal('Обработка запроса завершилась с ошибкой: ' + E.Message);
    end;
  finally
    FSocket.Free;
  end;
end;

procedure TWorkerThread.ProcessRequest;
var
  Header: string;
  Headers: TStringList;
  RequestLine: string;
  Path, Method: string;
  PathParts: TStringList;
  BaseName, DbfName, Operation: string;
  ConnStr: string;
  ContentLen: Integer;
  RawData: AnsiString;
  ContentStr: string;
  ResponseJson: string;
begin
  // 1. Читаем первую строку HTTP-запроса (напр. "GET /base1/orders/export HTTP/1.1")
  RequestLine := FSocket.RecvString(5000);
  if RequestLine = '' then Exit;

  FLogger.Debug('Request: ' + RequestLine);

  // Выделяем метод и путь
  Method := Copy(RequestLine, 1, Pos(' ', RequestLine) - 1);
  Path := Copy(RequestLine, Length(Method) + 2, MaxInt);
  Path := Copy(Path, 1, Pos(' ', Path) - 1);

  Headers := TStringList.Create;

  try
    // 2. Читаем остальные заголовки (до пустой строки)
    ContentLen := 0;
    repeat
      Header := FSocket.RecvString(5000);
      Headers.Add(Header);
      if Pos('Content-Length:', Header) > 0 then
        ContentLen := StrToIntDef(Trim(Copy(Header, 16, MaxInt)), 0);
    until (Header = '') or (FSocket.LastError <> 0);

    FLogger.Debug('Headers: ' + sLineBreak + Headers.Text);

    // Если POST, читаем данные
    if (Method = 'POST') and (ContentLen > 0) then
    begin
      // Ждем появления данных тела, если их еще нет в буфере
//      if FSocket.WaitingData = 0 then
//        FSocket.CanRead(5000);

      // Читаем тело. RecvBufferStr — самый безопасный метод в Synapse для этого.
      RawData := FSocket.RecvBufferStr(ContentLen, 5000);

      if FSocket.LastError <> 0 then
      begin
        FLogger.Error('Ошибка чтения тела: ' + FSocket.LastErrorDesc);
        SendResponse(400, 'Bad Request', 'application/json', '{"error":"Error read content' +
          FSocket.LastErrorDesc.
            Replace('"', '\"' ).
            Replace(sLineBreak, '\n').
            Replace(#13, '\n').
            Replace(#10, '\n') + '"}');
        Exit;
      end;

      // Декодируем из UTF-8
      ContentStr := TEncoding.UTF8.GetString(TEncoding.ANSI.GetBytes(RawData));
    end;

    // 3. Парсим путь /base_name/dbf_name/operation
    PathParts := TStringList.Create;
    try
      PathParts.StrictDelimiter := True;
      PathParts.Delimiter := '/';
      PathParts.DelimitedText := Path;

      // Поскольку путь начинается с '/', первый элемент будет пустым
      // Путь: /base1/orders/export -> Parts: ["", "base1", "orders", "export"]
      if PathParts.Count >= 4 then
      begin
        BaseName  := PathParts[1];
        DbfName   := PathParts[2];
        Operation := PathParts[3];

        FLogger.Info(Format('Task: Base=%s, Table=%s, Op=%s', [BaseName, DbfName, Operation]));

        // BaseName мы получили из разбора пути /base_name/dbf_name/export
        ConnStr := TConfigManager.GetInstance.GetConnectionString(BaseName);

        if ConnStr = '' then
        begin
          SendResponse(404, 'Not Found', 'application/json', '{"error":"Alias not found"}');
          Exit;
        end;

        // 4. Логика обработки операции
        if SameText(Operation, 'export') then
        begin
          TDataExporter.ExportTableToSocket(TConfigManager.GetInstance.GetConnectionString(BaseName), DbfName, FSocket);
        end
        else if SameText(Operation, 'execute') then // Например, /base/table/execute
        begin
          ResponseJson := TQueryHandler.ExecuteCommand(ConnStr, ContentStr);
          SendResponse(200, 'OK', 'application/json', ResponseJson);
        end
        else
          SendResponse(404, 'Not Found', 'application/json', '{"error":"Unknown operation"}');
      end
      else
        SendResponse(400, 'Bad Request', 'application/json', '{"error":"message":"Invalid path format"}');

    finally
      PathParts.Free;
    end;
  finally
    Headers.Free;
  end;
end;

procedure TWorkerThread.SendResponse(Code: Integer; const Status, ContentType,
  Body: string);
var
  Response: string;
begin
  Response := 'HTTP/1.1 ' + IntToStr(Code) + ' ' + Status + #13#10 +
              'Content-Type: ' + ContentType + #13#10 +
              'Content-Length: ' + IntToStr(Length(Body)) + #13#10 +
              'Connection: close' + #13#10 +
              #13#10 +
              Body;
  FSocket.SendString(Response);
end;

end.
