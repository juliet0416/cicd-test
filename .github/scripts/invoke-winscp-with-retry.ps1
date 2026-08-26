[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WinScpPath,

    [Parameter(Mandatory = $true)]
    [string]$LogPath,

    [Parameter(Mandatory = $true)]
    [string[]]$Commands,

    [int]$MaxAttempts = 3
)

$ErrorActionPreference = 'Stop'

if ($MaxAttempts -lt 1) {
    throw 'MaxAttempts must be at least 1.'
}
if (-not (Test-Path -LiteralPath $WinScpPath)) {
    throw "WinSCP executable does not exist: $WinScpPath"
}
if ($Commands.Count -eq 0) {
    throw 'At least one WinSCP command is required.'
}

$lastExitCode = 1
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $attemptLog = "$LogPath.attempt-$attempt.log"
    Write-Host "Starting WinSCP attempt $attempt of $MaxAttempts."

    & $WinScpPath "/log=$attemptLog" /command @Commands
    $lastExitCode = $LASTEXITCODE
    if ($lastExitCode -eq 0) {
        Write-Host "WinSCP operation completed on attempt $attempt."
        exit 0
    }

    Write-Warning "WinSCP attempt $attempt failed with exit code $lastExitCode."
    if ($attempt -lt $MaxAttempts) {
        Start-Sleep -Seconds (15 * $attempt)
    }
}

Write-Error "WinSCP operation failed after $MaxAttempts attempts."
exit $lastExitCode
