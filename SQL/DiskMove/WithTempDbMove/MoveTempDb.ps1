<#
.SYNOPSIS
    Moves SQL Server TempDB to the ephemeral (temporary) disk on an Azure VM.

.DESCRIPTION
    This script checks the size of TempDB and verifies that the ephemeral disk (e.g., D:) has enough free space
    before moving TempDB there, following Microsoft's best practices.
#>

param(
    [string]$SqlInstance = "localhost",
    [string]$EphemeralDrive = "D:",
    [int]$SafetyMarginMB = 512, 
    [string]$LogFolder = "C:\Temp"
)

$LogFile = "$LogFolder\TempDBMove_$(Get-Date -Format yyyyMMdd_HHmmss).log"

### --- LOGGING FUNCTION ---
function Log {
    param([string]$Message)
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $Line = "$Timestamp - $Message"
    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
}

try {

    Log "=== Checking Disk and TempDB Status on $SqlInstance ==="

    Import-Module SqlServer -ErrorAction Stop

# --- Step 1: Verify the ephemeral disk exists ---
if (!(Test-Path $EphemeralDrive)) {
    Log "Ephemeral drive $EphemeralDrive not found. Exiting."
    throw
}

$SQLServiceAccount = ""
    try {
        $query = "SELECT ServiceName = servicename, StartupType = startup_type_desc, ServiceStatus = status_desc, StartupTime = last_startup_time, ServiceAccount = service_account, IsIFIEnabled = instant_file_initialization_enabled FROM sys.dm_server_services;"
        $serviceInfo = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $query -TrustServerCertificate
        $service = $serviceInfo | Where-Object { $_.ServiceName -eq "SQL Server (MSSQLSERVER)" }
        $SQLServiceAccount = $service.ServiceAccount
        Log "Found Service account: $SQLServiceAccount"
    }
    catch {
        Log "Failed to retrieve SQL Service account: $($_.Exception.Message)" "Error"
        throw
    }

Log "Adding Permissions"
try {
    $acl = Get-Acl $EphemeralDrive
    $permission = "$SQLServiceAccount","FullControl","Allow"
    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
    $acl.SetAccessRule($accessRule)
    Set-Acl $EphemeralDrive $acl -Confirm
}
catch {
    Write-Err "Failed to Add Permissions on $EphemeralDrive : $($_.Exception.Message)"
    throw
}


$disk = Get-PSDrive | Where-Object { $_.Name -eq $EphemeralDrive.TrimEnd(':') }
$freeSpaceMB = [math]::Round($disk.Free / 1MB, 2)
$totalSpaceMB = [math]::Round($disk.Used / 1MB + $freeSpaceMB, 2)
Log "Ephemeral Disk ($EphemeralDrive): Total = $totalSpaceMB MB, Free = $freeSpaceMB MB"

# --- Step 2: Check current TempDB size using SQL query ---
$checkTempdbQuery = @"
SELECT SUM(size) * 8 / 1024 AS TempdbSizeMB
FROM tempdb.sys.database_files;
"@

$tempdbSizeMB = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $checkTempdbQuery -TrustServerCertificate | Select-Object -ExpandProperty TempdbSizeMB

Log "Current TempDB size: $tempdbSizeMB MB"

if ($freeSpaceMB -lt ($tempdbSizeMB + $SafetyMarginMB)) {
    Log "Not enough free space on $EphemeralDrive. Required: $($tempdbSizeMB + $SafetyMarginMB) MB, Available: $freeSpaceMB MB."
    throw
}

# --- Step 3: Get current TempDB file locations ---
$getFileQuery = @"
SELECT name, physical_name 
FROM sys.master_files 
WHERE database_id = DB_ID('tempdb');
"@
$tempdbFiles = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $getFileQuery -TrustServerCertificate

# --- Step 4: Build ALTER DATABASE commands ---
$alterCommands = @()
foreach ($file in $tempdbFiles) {
    $fileName = Split-Path $file.physical_name -Leaf
    $newPath = Join-Path $EphemeralDrive "$fileName"
    $alterCommands += "ALTER DATABASE tempdb MODIFY FILE (NAME = [$($file.name)], FILENAME = N'$newPath');"
}

# --- Step 6: Execute ALTER DATABASE commands ---
Log "Updating TempDB file locations..."
$alterScript = $alterCommands -join "`n"
Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $alterScript -TrustServerCertificate
Log "TempDB file paths updated successfully."

Log "=== TempDB has been successfully moved to $EphemeralDrive\TempDB ==="

}
catch {
    Log ("ERROR: {0}" -f $_.Exception.Message)
    throw
}
