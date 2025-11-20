<#
.SYNOPSIS
Moves SQL Server user database files to new disks (separate data/log paths),
updates SQL instance default paths, and restarts SQL Server service.

.DESCRIPTION
Detaches user databases, moves .mdf/.ndf and .ldf files to new paths,
reattaches them, updates SQL Server default data/log registry values,
and restarts the SQL service. Skips system databases.


.PARAMETER DataPath
Destination folder for data files (.mdf, .ndf)

.PARAMETER LogPath
Destination folder for log files (.ldf)

.PARAMETER SqlInstance
Optional. SQL Server instance name (e.g. "localhost" or "Server\Instance") (default: localhost)

.PARAMETER DatabaseNames
Optional. Specific databases to move. If omitted, all user databases are moved.

.PARAMETER SqlServiceName
Optional. SQL Service name (default: MSSQLSERVER for default instance)

.EXAMPLE
.\MoveDatabases.ps1 -SqlInstance "localhost" -DataPath "F:\SQLData" -LogPath "G:\SQLLogs"
#>

param (

    [Parameter(Mandatory = $true)]
    [string]$DataPath,

    [Parameter(Mandatory = $true)]
    [string]$LogPath,

    [string]$SqlInstance = "localhost",

    [string[]]$DatabaseNames,

    [string]$SqlServiceName = "MSSQLSERVER"
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
$logFilePath   = Join-Path $scriptDir ("{0}-{1}.log" -f "MoveSQLDatabases", $timestamp)
$rollbackFilePath = Join-Path $scriptDir ("{0}-{1}-rollback.json" -f "MoveSQLDatabases", $timestamp)
$TranscriptStarted = $false

# Store rollback information
$rollbackData = @{
    Timestamp = $timestamp
    OriginalPaths = @{}
    MovedDatabases = @()
    OriginalRegistryPaths = @{}
}
# =============== loggers ===============


try {
    Start-Transcript -Path $logPath | Out-Null
    $TranscriptStarted = $true
    Write-Ok "Log started: $logFilePath "

    Write-Info "=== Starting SQL Database Move Script ==="
Write-Info "SQL Instance: $SqlInstance"
Write-Info "DataPath: $DataPath"
Write-Info "LogPath: $LogPath"
Write-Info "SQL Service: $SqlServiceName"
Write-Info "Log file: $LogFile"

# Load SQL Server module
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Warn "SqlServer module not found. Installing from PowerShell Gallery..." -ForegroundColor Yellow
    try {
        Install-Module -Name SqlServer -AllowClobber -Force -Scope CurrentUser -ErrorAction Stop
        Write-Ok "SqlServer module installed successfully." -ForegroundColor Green
    } catch {
        Write-Err "Failed to install SqlServer module. Please ensure you have internet access and the PowerShell Gallery is available."
        throw
    }
}

$SQLServiceAccount = ""
try {
    $query = "SELECT ServiceName = servicename ,StartupType = startup_type_desc	,ServiceStatus = status_desc,StartupTime = last_startup_time,ServiceAccount = service_account,IsIFIEnabled = instant_file_initialization_enabled FROM sys.dm_server_services;"
    $serviceInfo = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $query -TrustServerCertificate
    $service = $serviceInfo | Where-Object { $_.ServiceName -eq "SQL Server (MSSQLSERVER)" }
    $SQLServiceAccount = $service.ServiceAccount
}
catch {
    Write-Err "Failed to retrieve SQL Service account: $($_.Exception.Message)" "ERROR";
    throw
}

$confirmation = Read-Host "Do you want to continue? (Y/N)"
if ($confirmation -notin @("Y","y","Yes","yes")) {
    Write-Log "User cancelled operation before moving databases." "WARN"
    Write-Err "Operation cancelled. No changes made." -ForegroundColor Yellow
    throw
}

# Ensure destination paths exist
foreach ($path in @($DataPath, $LogPath)) {
    if (-not (Test-Path $path)) {
        Write-Info "Creating folder $path..." "INFO"
        try { New-Item -Path $path -ItemType Directory } 
        catch { Write-Err "Failed to create $path : $($_.Exception.Message)" "ERROR"; throw }
    }

        Write-Info "Adding Permissions"
        try {
            $acl = Get-Acl $path
            $permission = "$SQLServiceAccount","FullControl","Allow"
            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
            $acl.SetAccessRule($accessRule)
            Set-Acl $path $acl
        }
        catch {
            Write-Err "Failed to Add Permissions on $path : $($_.Exception.Message)" "Errir";
            throw
        }
}



# Get user databases if not specified
if (-not $DatabaseNames) {
    Write-Info "Fetching list of user databases..." "INFO"
    $query = "SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name;"
    try {
        $DatabaseNames = (Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $query -TrustServerCertificate).name
    } catch {
        Write-Info "Failed to query database list: $($_.Exception.Message)" "ERROR"
        exit 1
    }
}

Write-Info "The following databases will be moved:"
$DatabaseNames | ForEach-Object { Write-Info "  - $_" }
Write-Host ""
$confirmation = Read-Host "Do you want to continue? (Y/N)"
if ($confirmation -notin @("Y","y","Yes","yes")) {
    Write-Log "User cancelled operation before moving databases." "WARN"
    Write-Err "Operation cancelled. No changes made." -ForegroundColor Yellow
    throw
}

foreach ($db in $DatabaseNames) {
    Write-Info "Processing database: $db"
    if ($db -in @('master','model','msdb','tempdb')) {
        Write-Info "Skipping system database: $db" "WARN"
        continue
    }

    try {
        # Get file locations
        $fileQuery = "SELECT name, type_desc, physical_name FROM sys.master_files WHERE database_id = DB_ID('$db');"
        $files = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $fileQuery -TrustServerCertificate

        if (-not $files) {
            Write-Info "Database $db not found or inaccessible." "ERROR"
            continue
        }

        # Store original paths for rollback
        $rollbackData.OriginalPaths[$db] = @()
        foreach ($file in $files) {
            $rollbackData.OriginalPaths[$db] += @{
                name = $file.name
                type_desc = $file.type_desc
                physical_name = $file.physical_name
            }
        }

        # SINGLE_USER
        Write-Info "Setting $db to SINGLE_USER mode..."
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -TrustServerCertificate

        # Detach
        Write-Info "Detaching $db..."
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "EXEC sp_detach_db '$db';" -TrustServerCertificate

        $attachClauses = @()

        # Move each file
        foreach ($file in $files) {
            $source = $file.physical_name
            $name = Split-Path $source -Leaf
            $dest = if ($file.type_desc -eq "LOG") { Join-Path $LogPath $name } else { Join-Path $DataPath $name }

            Write-Info "Moving $($file.type_desc.ToLower()) file $name to $dest"
            Move-Item -Path $source -Destination $dest -Force
            $attachClauses += "(FILENAME = N'$dest')"
        }

        # Reattach
        $attachSQL = "CREATE DATABASE [$db] ON $($attachClauses -join ', ') FOR ATTACH;"
        Write-Info "Reattaching $db..."
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $attachSQL -TrustServerCertificate

        # MULTI_USER
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "ALTER DATABASE [$db] SET MULTI_USER;" -TrustServerCertificate
        
        # Add to successfully moved databases
        $rollbackData.MovedDatabases += $db
        Write-Ok "Database $db successfully moved."
    }
    catch {
        Write-Err "Error moving $db : $($_.Exception.Message)" "ERROR"
        Write-Warn "Attempting to restore database access..."
        try {
            Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "ALTER DATABASE [$db] SET MULTI_USER;" -TrustServerCertificate -ErrorAction SilentlyContinue
        } catch {}
        
        # Save rollback data before exiting
        $rollbackData | ConvertTo-Json -Depth 10 | Set-Content -Path $rollbackFilePath
        Write-Err "Rollback information saved to: $rollbackFilePath"
        throw "Database move failed for $db. Use rollback script to restore."
    }
}

# --- Store original registry values for rollback ---
Write-Info "Storing original registry values for rollback..."
try {
    $originalDataPath = (Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "EXEC xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultData';" -TrustServerCertificate).Data
    $originalLogPath = (Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "EXEC xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultLog';" -TrustServerCertificate).Data
    
    $rollbackData.OriginalRegistryPaths = @{
        DefaultData = $originalDataPath
        DefaultLog = $originalLogPath
    }
} catch {
    Write-Warn "Could not retrieve original registry paths: $($_.Exception.Message)"
}

# --- Update SQL instance-level default paths ---
Write-Info "Updating instance default data/log paths..."

$updatePathsSQL = @"
EXEC xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'DefaultData',
    REG_SZ,
    N'$DataPath';
EXEC xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'DefaultLog',
    REG_SZ,
    N'$LogPath';
"@

try {
    Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $updatePathsSQL -TrustServerCertificate
    Write-Info "Instance default paths updated successfully."
} catch {
    Write-Info "Failed to update instance-level default paths: $($_.Exception.Message)" "ERROR"
}

# --- Restart SQL Server service ---
Write-Info "Restarting SQL Server service ($SqlServiceName)..."
try {
    Restart-Service -Name $SqlServiceName -Force -ErrorAction Stop
    Write-Info "SQL Server service restarted successfully."
} catch {
    Write-Info "Failed to restart SQL Server service: $($_.Exception.Message)" "ERROR"
}

# Save successful rollback information
$rollbackData | ConvertTo-Json -Depth 10 | Set-Content -Path $rollbackFilePath

Write-Info "=== Script completed ==="
Write-Host "`n✅ Migration complete. Log saved to: $logFilePath" -ForegroundColor Green
Write-Host "📋 Rollback information saved to: $rollbackFilePath" -ForegroundColor Cyan
Write-Host "   Use this file with a rollback script if you need to revert changes." -ForegroundColor Cyan

}
catch {
    Write-Err ("ERROR: {0}" -f $_.Exception.Message)
    
    # Save rollback data on error
    if ($rollbackData) {
        try {
            $rollbackData | ConvertTo-Json -Depth 10 | Set-Content -Path $rollbackFilePath
            Write-Host "📋 Rollback information saved to: $rollbackFilePath" -ForegroundColor Yellow
        } catch {}
    }
    
    if ($TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
    throw
}

if ($TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
Write-Ok "Log saved: $logFilePath "