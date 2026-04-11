object DBFServer: TDBFServer
  OldCreateOrder = False
  OnCreate = ServiceCreate
  DisplayName = 'Visual FoxPro Data Provider'
  OnStart = ServiceStart
  OnStop = ServiceStop
  Height = 150
  Width = 215
end
