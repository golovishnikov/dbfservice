program DBFService;

uses
  Vcl.SvcMgr,
  Vcl.Forms,
  SysUtils,
  ServiceMain in 'ServiceMain.pas' {DBFServer: TService},
  DebugMain in 'DebugMain.pas' {frmDebugMain},
  Log4D in 'Log4D\Log4D.pas',
  LogInterface in 'Log4D\LogInterface.pas',
  blcksock in 'synapse\blcksock.pas',
  synacode in 'synapse\synacode.pas',
  synafpc in 'synapse\synafpc.pas',
  synaip in 'synapse\synaip.pas',
  synautil in 'synapse\synautil.pas',
  HttpServer in 'HttpServer.pas',
  synsock in 'synapse\synsock.pas',
  options in 'options.pas',
  HttpRequestWorker in 'HttpRequestWorker.pas',
  dbf_export in 'dbf_export.pas',
  XSuperJSON in 'superobject\XSuperJSON.pas',
  XSuperObject in 'superobject\XSuperObject.pas',
  dbf_query_executer in 'dbf_query_executer.pas';

{$R *.RES}

begin
  // Windows 2003 Server requires StartServiceCtrlDispatcher to be
  // called before CoRegisterClassObject, which can be called indirectly
  // by Application.Initialize. TServiceApplication.DelayInitialize allows
  // Application.Initialize to be called from TService.Main (after
  // StartServiceCtrlDispatcher has been called).
  //
  // Delayed initialization of the Application object may affect
  // events which then occur prior to initialization, such as
  // TService.OnCreate. It is only recommended if the ServiceApplication
  // registers a class object with OLE and is intended for use with
  // Windows 2003 Server.
  //
  // Application.DelayInitialize := True;
  //
  // Проверяем наличие ключа -app или /app в командной строке
  if FindCmdLineSwitch('app') then
  begin
    // РЕЖИМ ПРИЛОЖЕНИЯ
    Vcl.Forms.Application.Initialize;
    Vcl.Forms.Application.MainFormOnTaskbar := True;
    Vcl.Forms.Application.CreateForm(TfrmDebugMain, frmDebugMain);
  Vcl.Forms.Application.Run;
  end
  else
  begin
    // РЕЖИМ СЕРВИСА
    if not Vcl.SvcMgr.Application.DelayInitialize or Vcl.SvcMgr.Application.Installing then
      Vcl.SvcMgr.Application.Initialize;
    Vcl.SvcMgr.Application.CreateForm(TDBFServer, DBFServer);
    Vcl.SvcMgr.Application.CreateForm(TfrmDebugMain, frmDebugMain);
    Vcl.SvcMgr.Application.Run;
  end;
end.
