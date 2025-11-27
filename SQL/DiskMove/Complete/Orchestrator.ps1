

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
$LogFile = "$LogFolder\SQLDiskMigrationOrchestrator_$(Get-Date -Format yyyyMMdd_HHmmss).log"

### --- LOGGING FUNCTION ---
function Log {
    param([string]$Message)
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $Line = "$Timestamp - $Message"
    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
}

Log "=== SQL Disk Migration Script Started ==="
Log "Script Location: $ScriptLocation "

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

    Log "Checking for SqlServer PowerShell module..."

    if (-not (Get-Module -ListAvailable -Name SqlServer)) {
        Log "SqlServer module not found. Installing from PowerShell Gallery..."
        try {
            Install-Module -Name SqlServer -AllowClobber -Force -ErrorAction Stop
            Log "SqlServer module installed successfully."
        } catch {
            Log "Failed to install SqlServer module. Please ensure you have internet access and the PowerShell Gallery is available."
            throw
        }
    }

    

    if($null -ne $Config.tempdb)
    {
        Log "Moving TempDB as per configuration..."
        $ephemeralDrive = $Config.tempdb.ephemeralDrive
        $safetyMarginMB = $Config.tempdb.safetyMarginMB

        & $ScriptLocation\MoveTempDB.ps1 -EphemeralDrive $ephemeralDrive -SafetyMarginMB $safetyMarginMB -LogFolder $LogFolder

        Log "TempDB move script completed. TempDb moved to $ephemeralDrive "
    }

    Log "1. Stopping SQL Services"
    Stop-SqlServices

    if (!(Test-Path $ConfigFile)) {
        Log "ERROR: Config file '$ConfigFile' not found."
        throw "Config file '$ConfigFile' not found."
    }
    


    # Create array to store job information
    $Jobs = @()
    $JobResults = @()

    # Validate disks configuration
    if (-not $Config.disks -or $Config.disks.Count -eq 0) {
        Log "No disks configured in config.json. Skipping migration."
    } else
    {
         foreach ($entry in $Config.disks) {
            $oldDrive = $entry.oldDrive
            $newDrive = $entry.newDrive
            $tempDrive = if ($entry.tempLetter) { $entry.tempLetter } else { $TempDrive }
            $runNumber = $entry.oldDrive.TrimEnd(':')

            if( -not $oldDrive -or -not $newDrive) {
                Log "ERROR: Invalid configuration entry: $($entry | ConvertTo-Json -Compress)"
                throw
            }

            Log "Starting parallel migration job for $oldDrive to $newDrive"

            # Start background job for each migration
            $Job = Start-Job -ScriptBlock {
                param($OldDrive, $NewDrive, $TempDrive, $LogFolder, $RunNumber, $ScriptPath)
                
                # Execute the disk change script
                & $ScriptPath -OldDrive $OldDrive -NewDrive $NewDrive -TempDrive $TempDrive -LogFolder $LogFolder -RunNumber $RunNumber
                
                # Return result info
                return @{
                    OldDrive = $OldDrive
                    NewDrive = $NewDrive
                    RunNumber = $OldDrive.TrimEnd(':')
                    Success = $?
                }
            } -ArgumentList $oldDrive, $newDrive, $tempDrive, $LogFolder, $runNumber, "$ScriptLocation\ChangeDisks.ps1"
            
            $Jobs += @{
                Job = $Job
                OldDrive = $oldDrive
                NewDrive = $newDrive
                RunNumber = $runNumber
            }
        }
        Log "Waiting for all migration jobs to complete..."

        # Wait for all jobs to complete in parallel
        foreach ($JobInfo in $Jobs) {
            Log "Waiting for job: $($JobInfo.OldDrive) -> $($JobInfo.NewDrive) (Job ID: $($JobInfo.Job.Id))"
            Wait-Job -Job $JobInfo.Job | Out-Null
            Log "Job completed: $($JobInfo.OldDrive) -> $($JobInfo.NewDrive) (Job ID: $($JobInfo.Job.Id))"
        }

        # Collect results from all completed jobs
        foreach ($JobInfo in $Jobs) {
            $Result = Receive-Job -Job $JobInfo.Job
            $JobResults += $Result
            Remove-Job -Job $JobInfo.Job
            
            if ($Result.Success) {
                Log "Migration completed for $($Result.OldDrive) -> $($Result.NewDrive)"
            } else {
                Log "ERROR: Migration failed for $($Result.OldDrive) -> $($Result.NewDrive)"
            }
        }

        Log "All migration jobs completed successfully. Proceeding with post-migration tasks..."

        # Process LUN information for all completed migrations
        foreach ($Result in $JobResults | Where-Object { $_.Success }) {
            try {
                $driveLetter = $Result.NewDrive.TrimEnd(':')
                Log "Getting LUN for drive $($Result.NewDrive)..."
                
                $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue
                if ($partition) {
                    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction SilentlyContinue
                    if ($disk -and $disk.Location) {
                        if ($disk.Location -match 'Lun\s*(\d+)') {
                            $lunNumber = $matches[1]
                            Log "LUN Number for $($Result.NewDrive) removal: $lunNumber"
                            
                            $removalFile = "$LogFolder\LUN_Removal_$($driveLetter)_$(Get-Date -Format yyyyMMdd_HHmmss).txt"
                            "Drive: $($Result.NewDrive)" | Out-File -FilePath $removalFile -Encoding UTF8
                            "LUN: $lunNumber" | Out-File -FilePath $removalFile -Encoding UTF8 -Append
                            "Location: $($disk.Location)" | Out-File -FilePath $removalFile -Encoding UTF8 -Append
                            Log "LUN information saved to: $removalFile"
                        } else {
                            Log "WARNING: Could not extract LUN number from location: $($disk.Location)"
                        }
                    } else {
                        Log "WARNING: Could not retrieve disk information for drive $($Result.NewDrive)"
                    }
                } else {
                    Log "WARNING: Could not find partition for drive $($Result.NewDrive)"
                }
            }
            catch {
                Log "ERROR retrieving LUN information for $($Result.NewDrive): $_"
            }
        }

        Log "All migrations completed. Please remove the following drives:"
        foreach ($Result in $JobResults | Where-Object { $_.Success }) {
            Log "  - $($Result.NewDrive)"
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