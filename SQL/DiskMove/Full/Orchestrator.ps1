

param(
    [switch]$HasSSASRunning,
    [switch]$HasSSASCeipRunning,
    [string]$TempDrive = "Z:",
    [string]$LogFolder = "C:\Temp",
    [string]$ConfigFile = "config.json"
)

# Read and process config.json
if (!(Test-Path $ConfigFile)) {
    Write-Error "Config file '$ConfigFile' not found."
    exit 1
}


$SqlServices = @("MSSQLSERVER","SQLSERVERAGENT")

if($HasSSASRunning) {
    $SqlServices += "MSSQLServerOLAPService"
}

if($HasSSASCeipRunning) {
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

try {
    Log "1. Stopping SQL Services"
    Stop-SqlServices

    if (!(Test-Path $ConfigFile)) {
        Log "ERROR: Config file '$ConfigFile' not found."
        throw "Config file '$ConfigFile' not found."
    }
    
    $Config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

    foreach ($entry in $Config) {
        $oldDrive = $entry.oldDrive
        $newDrive = $entry.newDrive
        $tempDrive = if ($entry.tempLetter) { $entry.tempLetter } else { $TempDrive }

        Log "Starting migration from $oldDrive to $newDrive and swapping drive letters"

        .\ChangeDisks.ps1 -OldDrive $oldDrive -NewDrive $newDrive -TempDrive $tempDrive -LogFolder $LogFolder -RunNumber ([array]::IndexOf($Config, $entry) + 1)

        Log "Migration completed for $oldDrive  please remove $newDrive"

        # Get LUN number for the new drive to facilitate removal
        try {
            $driveLetter = $newDrive.TrimEnd(':')
            Log "Getting LUN for drive $newDrive..."
            
            $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue
            if ($partition) {
                $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction SilentlyContinue
                if ($disk -and $disk.Location) {
                    # Extract LUN from location string (format: Integrated : Bus 0 : Device 63667 : Function : 30747 : Adapter 1 : Port 0 : Target : Lun1)
                    if ($disk.Location -match 'Lun\s*(\d+)') {
                        $lunNumber = $matches[1]
                        Log "LUN Number for $newDrive removal: $lunNumber"
                        
                        # Save LUN info to file
                        $removalFile = "$LogFolder\LUN_Removal_$($driveLetter)_$(Get-Date -Format yyyyMMdd_HHmmss).txt"
                        "Drive: $newDrive" | Out-File -FilePath $removalFile -Encoding UTF8
                        "LUN: $lunNumber" | Out-File -FilePath $removalFile -Encoding UTF8 -Append
                        "Location: $($disk.Location)" | Out-File -FilePath $removalFile -Encoding UTF8 -Append
                        Log "LUN information saved to: $removalFile"
                    } else {
                        Log "WARNING: Could not extract LUN number from location: $($disk.Location)"
                    }
                } else {
                    Log "WARNING: Could not retrieve disk information for drive $newDrive"
                }
            } else {
                Log "WARNING: Could not find partition for drive $newDrive"
            }
        }
        catch {
            Log "ERROR retrieving LUN information for $newDrive : $_"
        }

    }

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