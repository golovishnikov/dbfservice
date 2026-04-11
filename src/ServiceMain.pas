unit ServiceMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.SvcMgr, Vcl.Dialogs, HttpServer;

type
  TDBFServer = class(TService)
    procedure ServiceStart(Sender: TService; var Started: Boolean);
    procedure ServiceStop(Sender: TService; var Stopped: Boolean);
    procedure ServiceCreate(Sender: TObject);
  private
    FServerThread: TListeningThread;
  public
    function GetServiceController: TServiceController; override;
    { Public declarations }
  end;

var
  DBFServer: TDBFServer;

implementation

uses
  LogInterface, options;

{$R *.dfm}

procedure ServiceController(CtrlCode: DWord); stdcall;
begin
  DBFServer.Controller(CtrlCode);
end;

function TDBFServer.GetServiceController: TServiceController;
begin
  Result := ServiceController;
end;

procedure TDBFServer.ServiceCreate(Sender: TObject);
var
  ExeName: string;
begin
  // Получаем имя файла без расширения (например, 'VpfServer')
  ExeName := ChangeFileExt(ExtractFileName(ParamStr(0)), '');

  // Устанавливаем системное имя сервиса
  Self.Name := ExeName;

  // Устанавливаем отображаемое имя (то, что в списке служб)
  Self.DisplayName := ExeName + ' (Visual FoxPro Data Provider)';
end;

procedure TDBFServer.ServiceStart(Sender: TService; var Started: Boolean);
begin
  LogInterface.Log4DReconfig;
  TConfigManager.Initialize(options.AppIniFile);
  FServerThread := TListeningThread.Create(TConfigManager.GetInstance.Port);
  Started := True;
end;

procedure TDBFServer.ServiceStop(Sender: TService; var Stopped: Boolean);
begin
  if Assigned(FServerThread) then
  begin
    FServerThread.Terminate;
    FServerThread.WaitFor;
    FServerThread := nil;
  end;
  Stopped := True;
end;

end.
