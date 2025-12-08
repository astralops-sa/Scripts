

param(
    [string]$TempDrive = "Z:",
    [string]$LogFolder = "C:\Temp\Migration",
    [string]$ConfigFile = "config.json"
)

# Read and process config.json
if (!(Test-Path $ConfigFile)) {
    Write-Error "Config file '$ConfigFile' not found."
    exit 1
}

$ScriptLocation = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
$Config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
$SqlServices = $Config.services

if (!(Test-Path $LogFolder)) { 
    New-Item -ItemType Directory -Path $LogFolder | Out-Null 
}
$LogFile = "$LogFolder\SQLDiskMigrationRollBack_$(Get-Date -Format yyyyMMdd_HHmmss).log"

### --- LOGGING FUNCTION ---
function Log {
    param([string]$Message)
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $Line = "$Timestamp - $Message"
    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
}

## --- Helper Functions --- 
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

Log "=== SQL Disk Migration Script Started ==="
Log "Script Location: $ScriptLocation "

