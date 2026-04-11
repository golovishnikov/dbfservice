unit HttpServer;

interface

uses
  System.Classes, System.SysUtils, blcksock, synsock, Log4D;

type
  TListeningThread = class(TThread)
  private
    FPort: string;
    FSocket: TTCPBlockSocket;
    FLogger: TLogLogger;
  protected
    procedure Execute; override;
  public
    constructor Create(const APort: string);
    destructor Destroy; override;
  end;

implementation

uses
  HttpRequestWorker;



{ TListeningThread }

constructor TListeningThread.Create(const APort: string);
begin
  FPort := APort;
  FLogger := TLogLogger.GetLogger(TListeningThread.ClassName);
  inherited Create(False);
end;

destructor TListeningThread.Destroy;
begin
  if Assigned(FSocket) then
    FSocket.Free;
  inherited;
end;

procedure TListeningThread.Execute;
var
  ClientHandle: TSocket;
begin
  FSocket := TTCPBlockSocket.Create;
  try
    try
      FSocket.CreateSocket;
      FSocket.SetLinger(True, 1000);
      FSocket.Bind('0.0.0.0', FPort);

      if FSocket.LastError <> 0 then
      begin
        FLogger.Error('Ошибка Bind на порту ' + FPort + ': ' + FSocket.LastErrorDesc);
        Exit;
      end;

      FSocket.Listen;
      FLogger.Info('Сервер запущен на порту ' + FPort);

      while not Terminated do
      begin
        // CanRead(1000) — критически важно!
        // Ждем входящее соединение 1 секунду. Если за это время никто не пришел,
        // цикл проверит флаг Terminated и пойдет на новую итерацию.
        if FSocket.CanRead(1000) then
        begin
          ClientHandle := FSocket.Accept;
          if FSocket.LastError = 0 then
          begin
            FLogger.Debug('Новое подключение, Handle: ' + IntToStr(ClientHandle));
            TWorkerThread.Create(ClientHandle);
          end;
        end;
      end;

      FLogger.Info('Поток прослушивания завершил работу.');
    except
      on E: Exception do
      begin
        FLogger.Info('Поток прослушивания завершил работу из-за ошибки: ' + E.Message);
      end;
    end;
  finally
    FSocket.Free;
    FSocket := nil;
  end;
end;

end.
