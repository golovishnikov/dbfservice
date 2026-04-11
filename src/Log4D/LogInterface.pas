unit LogInterface;

interface

uses Windows, Classes, Log4D;

procedure Log4DReconfig; overload;
procedure Log4DReconfig(Props: TStringList); overload;
    { Имя конфигурационного файла }
function Log4DConfigFileName: String;
// отключить логгирование
procedure DisableLogs;

implementation

uses SysUtils;

const
  CRLF = sLIneBreak;
  defConfig =
    'log4d.appender.logfile=TLogRollingFileAppender' + CRLF +
    'log4d.appender.logfile.maxFileSize=10000KB' + CRLF +
    'log4d.appender.logfile.maxBackupIndex=3' + CRLF +
    'log4d.appender.logfile.append=true' + CRLF +
    'log4d.appender.logfile.lockingModel=InterProcessLock' + CRLF +
    'log4d.appender.logfile.fileName=app_log4d.log' + CRLF +
    'log4d.appender.logfile.layout=TLogPatternLayout' + CRLF +
    'log4d.appender.logfile.layout.dateFormat=yyyy-mm-dd hh:nn:ss.zzz' + CRLF +
    'log4d.appender.logfile.layout.pattern=%d %p [%c] (%h:%w:%a:%t) - %m%n' + CRLF + CRLF +
    'log4d.rootLogger=debug,logfile';

  disabledConfig =
    'log4d.appender.logfile=TLogRollingFileAppender' + CRLF +
    'log4d.appender.logfile.maxFileSize=1KB' + CRLF +
    'log4d.appender.logfile.maxBackupIndex=1' + CRLF +
    'log4d.appender.logfile.append=true' + CRLF +
    'log4d.appender.logfile.lockingModel=InterProcessLock' + CRLF +
    'log4d.appender.logfile.fileName=app_log4d.log' + CRLF +
    'log4d.appender.logfile.layout=TLogPatternLayout' + CRLF +
    'log4d.appender.logfile.layout.dateFormat=yyyy-mm-dd hh:nn:ss.zzz' + CRLF +
    'log4d.appender.logfile.layout.pattern=%d %p [%c] (%h:%w:%a:%t) - %m%n' + CRLF + CRLF +
    'log4d.rootLogger=off,logfile';

  DEFAULT_PARAMS =  'log4d.appender.httplog=TLogHttpAppender' + sLineBreak +
                    'log4d.appender.httplog.layout=TLogJsonLayout' + sLineBreak +
                    'log4d.appender.httplog.layout.dateFormat=yyyy-mm-dd''T''hh:nn:ss.zzz' + sLineBreak +
                    '' + sLineBreak +
                    'log4d.logger.TFIBSQLLogWriterThread=debug,httplog';


procedure Log4DReconfig;
var
  FSL: TStringList;
//  RSL: TStringList;
//  I: Integer;
//  PName: string;
begin
  FSL := TStringList.Create;
//  RSL := TStringList.Create;
  try
    FSL.LoadFromFile(Log4DConfigFileName);
//    RSL.Text := DEFAULT_PARAMS;
//    for I:=0 to Pred(RSL.Count) do
//    begin
//      PName := RSL.Names[I];
//      if Trim(PName) <> '' then
//        FSL.Values[PName] := RSL.ValueFromIndex[I];
//    end;
    Log4DReconfig(FSL);
  finally
    FSL.Free;
//    RSL.Free;
  end;
end;

procedure DisableLogs;
var
  FSL: TStringList;
begin
  FSL := TStringList.Create;
  try
    FSL.Text := disabledConfig;
    Log4DReconfig(FSL);
  finally
    FSL.Free;
  end;
end;

procedure Log4DReconfig(Props: TStringList);
begin
  try
    TLogPropertyConfigurator.ResetConfiguration;
    TLogPropertyConfigurator.Configure(Props);
  finally
  end;
end;

function Log4DConfigFileName: String;
var
  SL: TStringList;
begin
  Result := ExtractFilePath(GetModuleName(0)) + 'log4d.cfg';
  if not FileExists(Result) then
  begin
    SL := TStringList.Create;
    try
      SL.Text := defConfig;
      SL.SaveToFile(Result);
    finally
      SL.Free;
    end;
  end;
end;

end.
