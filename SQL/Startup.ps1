$folder = "D:\TempDb"

$SQLservice = Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'" | Select-Object Name, StartName
$SQLServiceAccount = $SQLservice.StartName
 
if (!(Test-Path $folder)) {
    New-Item -ItemType Directory -Path $folder

    try {
        $acl = Get-Acl $folder
        $permission = "$SQLServiceAccount","FullControl","Allow"
        $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
        $acl.SetAccessRule($accessRule)
        Set-Acl $folder $acl
    }
    catch {
        Write-Output "Failed to Add Permissions on  : $($_.Exception.Message)"
    }
}
 
Start-Service -Name MSSQLSERVER
Start-Service -Name SQLSERVERAGENT