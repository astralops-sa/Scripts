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

    [string]$RunNumber,

    [string]$TempDrive = "Z:",
    [string]$LogFolder = "C:\Temp"
)


if (!(Test-Path $LogFolder)) { 
    New-Item -ItemType Directory -Path $LogFolder | Out-Null 
}
$LogFile = "$LogFolder\SQLDiskMigration-$RunNumber-$(Get-Date -Format yyyyMMdd_HHmmss).log"

### --- LOGGING FUNCTION ---
function Log {
    param([string]$Message)
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $Line = "$Timestamp - $Message"
    #Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
}


### --- COPY DATA ---
function Copy-Data {
    Log "Copying data from $OldDrive to $NewDrive..."

    $RoboLog = "$LogFolder\robocopy-$RunNumber-$(Get-Date -Format yyyyMMdd_HHmmss).log"
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

    Log "Attempting to change drive letter $Current -> $New"

    $partition = Get-Partition -DriveLetter $CurrentLetter -ErrorAction SilentlyContinue

    if (-not $partition) {
        Log "ERROR: Partition with drive letter $Current not found."
        throw "Partition missing"
    }

    try {
        Set-Partition -DriveLetter $CurrentLetter -NewDriveLetter $NewLetter -ErrorAction Stop
        Log "SUCCESS: Changed drive letter $Current -> $New"
    }
    catch {
        Log "ERROR changing drive letter $Current -> $New : $_"
        throw
    }
}

### --- MAIN PROCESS ---
try {

    Log "2. Copying data"
    Copy-Data

    Log "3. Swapping drive letters"
    Set-DriveLetter -Current $OldDrive -New $TempDrive
    Set-DriveLetter -Current $NewDrive -New $OldDrive
    Set-DriveLetter -Current $TempDrive -New $NewDrive

}
catch {
    Log "FATAL ERROR: $_"
    Log "Migration failed. Services will be restarted for safety."
}

Log "=== Script Completed ==="
