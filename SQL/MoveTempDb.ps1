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
    [int]$SafetyMarginMB = 512  # extra buffer space to leave on the disk
)

$ErrorActionPreference = 'Stop'

# =============== helpers ===============
function Write-Info($m){ Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err($m){ Write-Host "[X] $m" -ForegroundColor Red }
# =============== helpers ===============
# =============== loggers ===============
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath   = Join-Path $scriptDir ("{0}-{1}.log" -f "MoveTempDB", $timestamp)
$TranscriptStarted = $false
# =============== loggers ===============

try {

    Start-Transcript -Path $logPath | Out-Null
    $TranscriptStarted = $true
    Write-Ok "Log started: $logPath"

   Write-Info "Checking for SqlServer PowerShell module..." -ForegroundColor Yellow

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Warn "SqlServer module not found. Installing from PowerShell Gallery..." -ForegroundColor Yellow
    try {
        Install-Module -Name SqlServer -AllowClobber -Force -ErrorAction Stop
        Write-Ok "SqlServer module installed successfully." -ForegroundColor Green
    } catch {
        Write-Err "Failed to install SqlServer module. Please ensure you have internet access and the PowerShell Gallery is available."
        throw
    }
}

    Write-Info "=== Checking Disk and TempDB Status on $SqlInstance ==="

# --- Step 1: Verify the ephemeral disk exists ---
if (!(Test-Path $EphemeralDrive)) {
    Write-Err "Ephemeral drive $EphemeralDrive not found. Exiting."
    throw
}

$disk = Get-PSDrive | Where-Object { $_.Name -eq $EphemeralDrive.TrimEnd(':') }
$freeSpaceMB = [math]::Round($disk.Free / 1MB, 2)
$totalSpaceMB = [math]::Round($disk.Used / 1MB + $freeSpaceMB, 2)
Write-Info "Ephemeral Disk ($EphemeralDrive): Total = $totalSpaceMB MB, Free = $freeSpaceMB MB"

# --- Step 2: Check current TempDB size using SQL query ---
$checkTempdbQuery = @"
SELECT SUM(size) * 8 / 1024 AS TempdbSizeMB
FROM tempdb.sys.database_files;
"@

$tempdbSizeMB = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $checkTempdbQuery -TrustServerCertificate | Select-Object -ExpandProperty TempdbSizeMB

Write-Info "Current TempDB size: $tempdbSizeMB MB"

if ($freeSpaceMB -lt ($tempdbSizeMB + $SafetyMarginMB)) {
    Write-Err "Not enough free space on $EphemeralDrive. Required: $($tempdbSizeMB + $SafetyMarginMB) MB, Available: $freeSpaceMB MB."
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
Write-Info "Updating TempDB file locations..."
$alterScript = $alterCommands -join "`n"
Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $alterScript -TrustServerCertificate
Write-Ok "TempDB file paths updated successfully."

# --- Step 7: Restart SQL Server service ---
$service = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
if (-not $service) {
    # For named instance
    $service = Get-Service | Where-Object { $_.Name -like "MSSQL$*" }
}

if ($service) {
    Write-Info "Restarting SQL Server service ($($service.Name))..."
    Restart-Service -Name $service.Name -Force -ErrorAction Stop
    Write-Ok "SQL Server restarted successfully."
} else {
    Write-Warn "SQL Server service not found. Please restart manually for changes to take effect."
}

Write-Ok "=== TempDB has been successfully moved to $EphemeralDrive ==="

}
catch {
    Write-Err ("ERROR: {0}" -f $_.Exception.Message)
    if ($TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
    throw
}

if ($TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
Write-Ok "Log saved: $logPath"