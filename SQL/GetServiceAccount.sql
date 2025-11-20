SELECT ServiceName = servicename
	,StartupType = startup_type_desc
	,ServiceStatus = status_desc
	,StartupTime = last_startup_time
	,ServiceAccount = service_account
	,IsIFIEnabled = instant_file_initialization_enabled
FROM sys.dm_server_services;