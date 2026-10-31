param(
    [ValidateSet('all', 'manual', 'thunderstore')]
    [string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'

# Keep the existing PowerShell entry point; all platforms use the same builder.
# This script never locates or installs into Balatro.
& python (Join-Path $PSScriptRoot 'tools/build.py') --target $Target
if ($LASTEXITCODE -ne 0) {
    throw "Mod packaging failed (exit code $LASTEXITCODE)."
}
