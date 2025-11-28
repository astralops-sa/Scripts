$folder = "D:\TempDB"
$SqlInstance = "localhost"
$SQLServiceAccount = ""
try {
	$query = "SELECT ServiceName = servicename, StartupType = startup_type_desc, ServiceStatus = status_desc, StartupTime = last_startup_time, ServiceAccount = service_account, IsIFIEnabled = instant_file_initialization_enabled FROM sys.dm_server_services;"
	$serviceInfo = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $query -TrustServerCertificate
	$service = $serviceInfo | Where-Object { $_.ServiceName -eq "SQL Server (MSSQLSERVER)" }
	$SQLServiceAccount = $service.ServiceAccount
	Where-Object "Found Service account: $SQLServiceAccount"
}
catch {
	Write-Output "Failed to retrieve SQL Service account: $($_.Exception.Message)"
}
 
if (!(Test-Path $folder)) {
    New-Item -ItemType Directory -Path $folder
}
 
try {
    $acl = Get-Acl $folder
    $permission = "$SQLServiceAccount","FullControl","Allow"
    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
    $acl.SetAccessRule($accessRule)
    Set-Acl $folder $acl
}
catch {
    Write-Output "Failed to Add Permissions on $EphemeralDrive : $($_.Exception.Message)"
}