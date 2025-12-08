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

### --- SQLCMD HELPER FUNCTION ---
function Invoke-SqlCmd2 {
    param(
        [string]$ServerInstance,
        [string]$Query
    )
    
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $Query | Out-File -FilePath $tempFile -Encoding ASCII
        
        $result = sqlcmd -S $ServerInstance -E -i $tempFile -h -1 -s "|" -W -C
        
        if ($LASTEXITCODE -ne 0) {
            throw "sqlcmd execution failed with exit code $LASTEXITCODE"
        }
        
        return $result
    }
    finally {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force
        }
    }
}

try {

    Log "=== Checking Disk and TempDB Status on $SqlInstance ==="

# --- Step 1: Verify the ephemeral disk exists ---
if (!(Test-Path $EphemeralDrive)) {
    Log "Ephemeral drive $EphemeralDrive not found. Exiting."
    throw
}

$SQLServiceAccount = ""
    try {
        $query = "SELECT service_account FROM sys.dm_server_services WHERE servicename = 'SQL Server (MSSQLSERVER)';"
        $result = Invoke-SqlCmd2 -ServerInstance $SqlInstance -Query $query
        $SQLServiceAccount = ($result | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1).Trim()
        Log "Found Service account: $SQLServiceAccount"
    }
    catch {
        Log "Failed to retrieve SQL Service account: $($_.Exception.Message)"
        throw
    }

$newDir = Join-Path $EphemeralDrive "TempDb"
if(!(Test-Path $newDir)) {
    Log "Creating TempDb directory at $newDir"
    New-Item -ItemType Directory -Path $newDir | Out-Null
} else {
    Log "TempDb directory already exists at $newDir"
}

Log "Adding Permissions"
try {
    $acl = Get-Acl "$EphemeralDrive\TempDb"
    $permission = "$SQLServiceAccount","FullControl","Allow"
    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
    $acl.SetAccessRule($accessRule)
    Set-Acl "$EphemeralDrive\TempDb" $acl
}
catch {
    Log "Failed to Add Permissions on $EphemeralDrive : $($_.Exception.Message)"
    throw
}

Write-Output "Checking free space on $EphemeralDrive..."

$disk = Get-PSDrive | Where-Object { $_.Name -eq $EphemeralDrive.TrimEnd(':') }
$freeSpaceMB = [math]::Round($disk.Free / 1MB, 2)
$totalSpaceMB = [math]::Round($disk.Used / 1MB + $freeSpaceMB, 2)
Log "Ephemeral Disk ($EphemeralDrive): Total = $totalSpaceMB MB, Free = $freeSpaceMB MB"

# --- Step 2: Check current TempDB size using SQL query ---
$checkTempdbQuery = @"
SELECT SUM(size) * 8 / 1024 AS TempdbSizeMB
FROM tempdb.sys.database_files;
"@

$result = Invoke-SqlCmd2 -ServerInstance $SqlInstance -Query $checkTempdbQuery
$tempdbSizeMB = ($result | Where-Object { $_.Trim() -ne "" -and $_.Trim() -notlike "*-*" } | Select-Object -First 1).Trim()

Log "Current TempDB size: $tempdbSizeMB MB"

if ($freeSpaceMB -lt ($tempdbSizeMB + $SafetyMarginMB)) {
    Log "Not enough free space on $EphemeralDrive. Required: $($tempdbSizeMB + $SafetyMarginMB) MB, Available: $freeSpaceMB MB."
    exit 1
}

# --- Step 3: Get current TempDB file locations ---
$getFileQuery = @"
SELECT name + '|' + physical_name AS FileInfo
FROM sys.master_files 
WHERE database_id = DB_ID('tempdb');
"@
$result = Invoke-SqlCmd2 -ServerInstance $SqlInstance -Query $getFileQuery
$tempdbFiles = $result | Where-Object { $_.Trim() -ne "" -and $_ -like "*|*" }

# --- Step 4: Build ALTER DATABASE commands ---
$alterCommands = @()
foreach ($fileLine in $tempdbFiles) {
    $parts = $fileLine.Trim() -split '\|'
    if ($parts.Count -eq 2) {
        $name = $parts[0].Trim()
        $physicalName = $parts[1].Trim()
        $fileName = Split-Path $physicalName -Leaf
        $newPath = Join-Path $EphemeralDrive "TempDb\$fileName"
        $alterCommands += "ALTER DATABASE tempdb MODIFY FILE (NAME = [$name], FILENAME = N'$newPath');"
    }
}

# --- Step 6: Execute ALTER DATABASE commands ---
Log "Updating TempDB file locations..."
$alterScript = $alterCommands -join "`n"
Invoke-SqlCmd2 -ServerInstance $SqlInstance -Query $alterScript | Out-Null
Log "TempDB file paths updated successfully."

Log "=== TempDB has been successfully moved to $EphemeralDrive\TempDB ==="

}
catch {
    Log ("ERROR: {0}" -f $_.Exception.Message)
    throw
}
