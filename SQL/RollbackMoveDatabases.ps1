<#
.SYNOPSIS
Rollback script for MoveDatabases.ps1 - restores databases to original locations

.DESCRIPTION
This script reads the rollback JSON file created by MoveDatabases.ps1 and restores
databases to their original file locations and registry settings.

.PARAMETER RollbackFilePath
Path to the rollback JSON file created by MoveDatabases.ps1

.PARAMETER SqlInstance
Optional. SQL Server instance name (default: localhost)

.PARAMETER SqlServiceName
Optional. SQL Service name (default: MSSQLSERVER)

.EXAMPLE
.\RollbackMoveDatabases.ps1 -RollbackFilePath "MoveSQLDatabases-20241120-143022-rollback.json"
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$RollbackFilePath,

    [string]$SqlInstance = "localhost",
    [string]$SqlServiceName = "MSSQLSERVER"
)

$ErrorActionPreference = 'Stop'

# =============== helpers ===============
function Write-Info($m){ Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err($m){ Write-Host "[X] $m" -ForegroundColor Red }
# =============== helpers ===============

try {
    # Validate rollback file exists
    if (-not (Test-Path $RollbackFilePath)) {
        throw "Rollback file not found: $RollbackFilePath"
    }

    # Load rollback data
    Write-Info "Loading rollback data from: $RollbackFilePath"
    $rollbackData = Get-Content -Path $RollbackFilePath | ConvertFrom-Json

    Write-Info "=== Starting Database Rollback ==="
    Write-Info "Original migration timestamp: $($rollbackData.Timestamp)"
    Write-Info "Databases to rollback: $($rollbackData.MovedDatabases -join ', ')"
    
    Write-Host ""
    $confirmation = Read-Host "⚠️  This will move databases back to original locations. Continue? (Y/N)"
    if ($confirmation -notin @("Y","y","Yes","yes")) {
        Write-Warn "Rollback cancelled by user."
        return
    }

    # Rollback each database
    foreach ($dbName in $rollbackData.MovedDatabases) {
        if (-not $rollbackData.OriginalPaths.$dbName) {
            Write-Warn "No original path data found for database: $dbName"
            continue
        }

        Write-Info "Rolling back database: $dbName"
        
        try {
            # Get current file locations
            $currentFileQuery = "SELECT name, type_desc, physical_name FROM sys.master_files WHERE database_id = DB_ID('$dbName');"
            $currentFiles = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $currentFileQuery -TrustServerCertificate

            # Set to SINGLE_USER
            Write-Info "Setting $dbName to SINGLE_USER mode..."
            Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -TrustServerCertificate

            # Detach database
            Write-Info "Detaching $dbName..."
            Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "EXEC sp_detach_db '$dbName';" -TrustServerCertificate

            # Move files back to original locations
            $attachClauses = @()
            foreach ($originalFile in $rollbackData.OriginalPaths.$dbName) {
                # Find current file location
                $currentFile = $currentFiles | Where-Object { $_.name -eq $originalFile.name }
                if ($currentFile) {
                    $currentPath = $currentFile.physical_name
                    $originalPath = $originalFile.physical_name
                    
                    Write-Info "Moving $($originalFile.type_desc.ToLower()) file back: $(Split-Path $currentPath -Leaf)"
                    Write-Info "  From: $currentPath"
                    Write-Info "  To:   $originalPath"
                    
                    # Ensure destination directory exists
                    $destDir = Split-Path $originalPath -Parent
                    if (-not (Test-Path $destDir)) {
                        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                    }
                    
                    Move-Item -Path $currentPath -Destination $originalPath -Force
                    $attachClauses += "(FILENAME = N'$originalPath')"
                }
            }

            # Reattach database
            if ($attachClauses.Count -gt 0) {
                $attachSQL = "CREATE DATABASE [$dbName] ON $($attachClauses -join ', ') FOR ATTACH;"
                Write-Info "Reattaching $dbName..."
                Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $attachSQL -TrustServerCertificate

                # Set back to MULTI_USER
                Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "ALTER DATABASE [$dbName] SET MULTI_USER;" -TrustServerCertificate
                Write-Ok "Database $dbName successfully rolled back."
            }
        }
        catch {
            Write-Err "Failed to rollback database $dbName : $($_.Exception.Message)"
            # Try to restore database access if possible
            try {
                Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "ALTER DATABASE [$dbName] SET MULTI_USER;" -TrustServerCertificate -ErrorAction SilentlyContinue
            } catch {}
        }
    }

    # Rollback registry settings
    if ($rollbackData.OriginalRegistryPaths -and 
        ($rollbackData.OriginalRegistryPaths.DefaultData -or $rollbackData.OriginalRegistryPaths.DefaultLog)) {
        
        Write-Info "Restoring original registry default paths..."
        
        try {
            if ($rollbackData.OriginalRegistryPaths.DefaultData) {
                $restoreDataPathSQL = @"
EXEC xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'DefaultData',
    REG_SZ,
    N'$($rollbackData.OriginalRegistryPaths.DefaultData)';
"@
                Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $restoreDataPathSQL -TrustServerCertificate
            }

            if ($rollbackData.OriginalRegistryPaths.DefaultLog) {
                $restoreLogPathSQL = @"
EXEC xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'DefaultLog',
    REG_SZ,
    N'$($rollbackData.OriginalRegistryPaths.DefaultLog)';
"@
                Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $restoreLogPathSQL -TrustServerCertificate
            }
            
            Write-Ok "Registry paths restored successfully."
        }
        catch {
            Write-Warn "Failed to restore registry paths: $($_.Exception.Message)"
        }
    }

    # Restart SQL Server service
    Write-Info "Restarting SQL Server service ($SqlServiceName)..."
    try {
        Restart-Service -Name $SqlServiceName -Force -ErrorAction Stop
        Write-Ok "SQL Server service restarted successfully."
    } catch {
        Write-Warn "Failed to restart SQL Server service: $($_.Exception.Message)"
    }

    Write-Info "=== Rollback completed ==="
    Write-Ok "✅ Databases have been restored to their original locations."
    
    # Archive the rollback file
    $archivePath = $RollbackFilePath -replace '\.json$', '-USED.json'
    Move-Item -Path $RollbackFilePath -Destination $archivePath
    Write-Info "Rollback file archived as: $archivePath"
}
catch {
    Write-Err "Rollback failed: $($_.Exception.Message)"
    throw
}