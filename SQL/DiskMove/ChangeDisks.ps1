<# ====================================================================
 PowerShell Script: SQL Server Disk Migration with Logging
 - Stops SQL services
 - Copies data to new disk
 - Swaps drive letters
 - Restarts SQL services
 - Full logging
 - Safe rollback: SQL services always restarted even during failure

 #TODO: Add switch flags as some services may use different services
==================================================================== #>

param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$OldDrive,

    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$NewDrive,

    [switch]$HasSSASRunning,
    [switch]$HasSSASCeipRunning,

    [string]$TempDrive = "Z:",
    [string]$LogFolder = "C:\Temp"
    
)

$SqlServices = @("MSSQLSERVER","SQLSERVERAGENT")

if($HasSSASRunning) {
    $SqlServices += "MSSQLSERVEROLAPService"
}

if($HasSSASRunning) {
    $SqlServices += "SSASTELEMETRY"
}


if (!(Test-Path $LogFolder)) { 
    New-Item -ItemType Directory -Path $LogFolder | Out-Null 
}
$LogFile = "$LogFolder\SQLDiskMigration_$(Get-Date -Format yyyyMMdd_HHmmss).log"

### --- LOGGING FUNCTION ---
function Log {
    param([string]$Message)
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $Line = "$Timestamp - $Message"
    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
}

Log "=== SQL Disk Migration Script Started ==="

### --- USER CONFIRMATION ---
Log "About to perform SQL Server disk migration:"
Log "  Old Drive: $OldDrive"
Log "  New Drive: $NewDrive"
Log "  Temp Drive: $TempDrive"
Log "  Services: $($SqlServices -join ', ')"
Write-Host ""
Write-Host "WARNING: This will stop SQL services and migrate data!" -ForegroundColor Yellow
$confirmation = Read-Host "Do you want to proceed? (y/N)"

if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
    Log "Migration cancelled by user."
    Write-Host "Migration cancelled." -ForegroundColor Red
    exit 0
}

Log "User confirmed - proceeding with migration..."

### --- SQL SERVICE STOP/START ---
function Stop-SqlServices {
    Log "Stopping SQL Services..."
    foreach ($svc in $SqlServices) {
        try {
            if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
                Stop-Service -Name $svc -Force -ErrorAction Stop
                Log "Stopped service: $svc"
            }
        }
        catch {
            Log "ERROR stopping service ${svc}: $_"
            throw
        }
    }
}

function Start-SqlServices {
    Log "Starting SQL Services..."
    foreach ($svc in $SqlServices) {
        try {
            if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
                Start-Service -Name $svc -ErrorAction Stop
                Log "Started service: $svc"
            }
        }
        catch {
            Log "ERROR starting service ${svc}: $_"
            throw
        }
    }
}

### --- COPY DATA ---
function Copy-Data {
    Log "Copying data from $OldDrive to $NewDrive..."

    $RoboLog = "$LogFolder\robocopy_$(Get-Date -Format yyyyMMdd_HHmmss).log"
    Log "Robocopy log file: $RoboLog"

    $result = robocopy `
        "$OldDrive\" `
        "$NewDrive\" `
        /MIR /COPYALL /SEC /R:1 /W:1 /LOG:"$RoboLog"

    Log "Robocopy exit code: $result"

    if ($result -ge 8) {
        Log "ERROR: Robocopy FAILURE detected (exit code $result)."
        throw "Robocopy failed. Migration aborted."
    }
    else {
        Log "Robocopy completed successfully."
    }
}

### --- DRIVE LETTER SWAP ---
function Set-DriveLetter {
    param(
        [string]$Current,
        [string]$New
    )

    $CurrentLetter = $Current.TrimEnd(":")
    $NewLetter = $New.TrimEnd(":")

    Log "Attempting to change drive letter $Current → $New"

    $partition = Get-Partition -DriveLetter $CurrentLetter -ErrorAction SilentlyContinue

    if (-not $partition) {
        Log "ERROR: Partition with drive letter $Current not found."
        throw "Partition missing"
    }

    try {
        Set-Partition -DriveLetter $CurrentLetter -NewDriveLetter $NewLetter -ErrorAction Stop
        Log "SUCCESS: Changed drive letter $Current → $New"
    }
    catch {
        Log "ERROR changing drive letter $Current → $New : $_"
        throw
    }
}

### --- MAIN PROCESS ---
try {
    Log "1. Stopping SQL Services"
    Stop-SqlServices

    Log "2. Copying data"
    Copy-Data

    Log "3. Swapping drive letters"
    Set-DriveLetter -Current $OldDrive -New $TempDrive
    Set-DriveLetter -Current $NewDrive -New $OldDrive
    Set-DriveLetter -Current $TempDrive -New $NewDrive

    Log "4. Starting SQL Services"
    Start-SqlServices

    Log "=== Migration Completed Successfully ==="
}
catch {
    Log "FATAL ERROR: $_"
    Log "Migration failed. Services will be restarted for safety."
}
finally {
    # Safety restart — always ensure SQL is running
    try {
        Log "Running final service restart (safety)..."
        Start-SqlServices
        Log "Safety SQL service restart complete."
    }
    catch {
        Log "ERROR during safety restart: $_"
    }
}

Log "=== Script Completed ==="
