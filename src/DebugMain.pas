unit DebugMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, HttpServer, DirectoryMonitorManager;

type
  TfrmDebugMain = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FServer: TListeningThread;
    FDirectoryMonitor: TDirectoryMonitor;
  public
    { Public declarations }
  end;

var
  frmDebugMain: TfrmDebugMain;

implementation

uses
  LogInterface, options;

{$R *.dfm}

procedure TfrmDebugMain.FormCreate(Sender: TObject);
begin
  LogInterface.Log4DReconfig;
  TConfigManager.Initialize(options.AppIniFile);
  FServer := TListeningThread.Create(TConfigManager.GetInstance.Port);
  FDirectoryMonitor := TDirectoryMonitor.Create();
end;

procedure TfrmDebugMain.FormDestroy(Sender: TObject);
begin
  FDirectoryMonitor.Free;
  FServer.Terminate;
  FServer.WaitFor;
end;

end.
