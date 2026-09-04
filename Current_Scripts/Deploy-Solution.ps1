<#
.SYNOPSIS
  End to end: fetch a solution from cloud storage, retarget its values, pack it,
  import it into an environment, and turn on agent sharing.

.DESCRIPTION
  A driver. It owns no solution-editing or sharing logic of its own - it calls
  the two scripts that already do that work, so a fix in either reaches this
  pipeline for free:

      Sol_workflow_vals.ps1   prompts for the values, rewrites them, packs
      Share-Agent.ps1         shares the agent and publishes

  Six steps, in order:

      1. Fetch    -SolutionUrl over https, or -SolutionPath from disk
      2. Prompt   Sol_workflow_vals.ps1 asks for anything not passed in
      3. Modify   the same script rewrites the SharePoint and Dataverse values
      4. Pack     and writes <name>_Changed.zip
      5. Import   pac solution import, with publish. Skip with -SkipImport
      6. Share    Share-Agent.ps1, org-wide by default

  Storage is deliberately dumb for the POC. Any https URL serving the zip works,
  catbox.moe included. The download is checked for a zip signature before
  anything is unpacked, because everything after step 1 trusts that file.

  Auth: the active `pac auth` profile for import and publish, and `az login` for
  the Dataverse calls the sharing step makes. Both must be in the same tenant as
  the target environment.

.EXAMPLE
  .\Deploy-Solution.ps1 -SolutionUrl https://files.catbox.moe/abc123.zip `
                        -TargetOrgUrl https://org35fd7a12.crm.dynamics.com
  Fetch, prompt for the values, pack, import, share with the organisation.

.EXAMPLE
  .\Deploy-Solution.ps1 -SolutionPath .\CUAExecutionValidator.zip `
                        -TargetOrgUrl https://org35fd7a12.crm.dynamics.com `
                        -SharePointUrl https://contoso.sharepoint.com/sites/AICOE `
                        -SkipImport -NoShare
  Dry run: rewrite and pack only, no environment is touched.

.EXAMPLE
  .\Deploy-Solution.ps1 -SolutionUrl https://files.catbox.moe/abc123.zip `
                        -TargetOrgUrl https://org35fd7a12.crm.dynamics.com `
                        -ShareUserEmail tester@contoso.com
  Share with one user at the end instead of the whole organisation.
#>
[CmdletBinding()]
param(
    [string] $SolutionUrl,
    [string] $SolutionPath,

    [string] $TargetOrgUrl,
    [string] $SharePointUrl,
    [string] $Bot = 'cr720_Agent1TestScript',

    [string] $OutFile,
    [ValidateSet('literal', 'envvar')]
    [string] $Mode = 'literal',
    [switch] $ResolveLibraryId,

    [string] $ShareUserEmail,
    [switch] $NoShare,
    [switch] $SkipImport,
    [switch] $KeepWork,
    [switch] $SelfTest
)
$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Text) Write-Host "`n=== $Text" -ForegroundColor Cyan }

# Everything downstream unpacks and imports this file, so check it is really a
# zip before trusting it. PK\x03\x04 is the local file header of every zip.
function Test-ZipSignature {
    param([string] $File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    $fs = [IO.File]::OpenRead($File)
    try {
        $b = [byte[]]::new(4)
        if ($fs.Read($b, 0, 4) -lt 4) { return $false }
        return $b[0] -eq 0x50 -and $b[1] -eq 0x4B -and $b[2] -eq 0x03 -and $b[3] -eq 0x04
    } finally { $fs.Dispose() }
}

if ($SelfTest) {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("dsz_" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    try {
        $txt = Join-Path $d 'a.txt'; 'hello' | Set-Content -LiteralPath $txt
        $zip = Join-Path $d 'a.zip'; Compress-Archive -Path $txt -DestinationPath $zip
        if (-not (Test-ZipSignature $zip)) { throw 'selftest: a real zip should pass' }
        if (Test-ZipSignature $txt)        { throw 'selftest: a text file should fail' }
        if (Test-ZipSignature (Join-Path $d 'nope.zip')) { throw 'selftest: a missing file should fail' }
        'ok'
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    return
}

if (-not $SolutionUrl -and -not $SolutionPath) { throw 'Pass -SolutionUrl or -SolutionPath.' }
if ($SolutionUrl -and $SolutionPath)           { throw 'Pass -SolutionUrl or -SolutionPath, not both.' }
if (-not $SkipImport -and -not $TargetOrgUrl)  { throw 'Pass -TargetOrgUrl, or -SkipImport to stop after packing.' }
if (-not $NoShare    -and -not $TargetOrgUrl)  { throw 'Pass -TargetOrgUrl, or -NoShare to stop before sharing.' }
if ($TargetOrgUrl) { $TargetOrgUrl = $TargetOrgUrl.Trim().TrimEnd('/') }

$prep  = Join-Path $PSScriptRoot 'Sol_workflow_vals.ps1'
$share = Join-Path $PSScriptRoot 'Share-Agent.ps1'
foreach ($s in $prep, $share) { if (-not (Test-Path -LiteralPath $s)) { throw "Missing sibling script: $s" } }

$work = Join-Path ([IO.Path]::GetTempPath()) ("deploysol_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    # --- 1. fetch -------------------------------------------------------------
    Write-Step 'Fetch solution'
    if ($SolutionUrl) {
        if ($SolutionUrl -notmatch '^https://') { throw "Refusing a non-https source: $SolutionUrl" }
        $src = Join-Path $work ([IO.Path]::GetFileName(([uri]$SolutionUrl).AbsolutePath))
        if (-not [IO.Path]::GetExtension($src)) { $src = Join-Path $work 'solution.zip' }
        Write-Host "  GET $SolutionUrl"
        Invoke-WebRequest -Uri $SolutionUrl -OutFile $src -MaximumRedirection 5
    } else {
        if (-not (Test-Path -LiteralPath $SolutionPath -PathType Leaf)) { throw "Not a file: $SolutionPath" }
        $src = (Resolve-Path -LiteralPath $SolutionPath).Path
    }
    if (-not (Test-ZipSignature $src)) {
        throw "Not a zip: $src. A catbox link that 404s saves the HTML error page under a .zip name, which looks like this."
    }
    Write-Host "  $src  $([math]::Round((Get-Item -LiteralPath $src).Length / 1KB)) KB"

    # --- 2-4. prompt, modify, pack -------------------------------------------
    # Sol_workflow_vals.ps1 prompts for whatever is not passed, so the prompting
    # step lives there rather than being reimplemented here.
    Write-Step 'Retarget values and pack'
    if (-not $OutFile) {
        $OutFile = Join-Path (Get-Location).Path ([IO.Path]::GetFileNameWithoutExtension($src) + '_Changed.zip')
    }
    $prepArgs = @{ Path = $src; OutFile = $OutFile; Mode = $Mode }
    if ($TargetOrgUrl)     { $prepArgs.OrgUrl           = $TargetOrgUrl }
    if ($SharePointUrl)    { $prepArgs.SharePointUrl    = $SharePointUrl }
    if ($ResolveLibraryId) { $prepArgs.ResolveLibraryId = $true }
    & $prep @prepArgs
    if (-not (Test-Path -LiteralPath $OutFile)) { throw "Packing reported success but $OutFile is not there." }

    # --- 5. import ------------------------------------------------------------
    if ($SkipImport) {
        Write-Step 'Import skipped (-SkipImport)'
    } else {
        Write-Step "Import into $TargetOrgUrl"
        $pac = (Get-Command pac, pac.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $pac) { $pac = "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\pac.cmd" }
        if (-not (Test-Path $pac)) { throw "pac not found - install from https://aka.ms/PowerAppsCLI. The packed solution is at $OutFile." }
        # pac.cmd swallows exit codes, so treat "Error:" in the output as failure too.
        $out = & $pac solution import --environment $TargetOrgUrl --path $OutFile `
                    --publish-changes --force-overwrite --activate-plugins --max-async-wait-time 60 2>&1 | ForEach-Object { "$_" }
        $out | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0 -or ($out -match '^\s*Error:')) {
            throw "Solution import failed. The packed solution is at $OutFile - check 'pac auth list' and import from the portal if needed."
        }
    }

    # --- 6. share -------------------------------------------------------------
    if ($NoShare) {
        Write-Step 'Sharing skipped (-NoShare)'
    } elseif ($SkipImport) {
        Write-Step 'Sharing skipped - nothing was imported'
    } else {
        Write-Step 'Enable agent sharing'
        $shareArgs = @{ OrgUrl = $TargetOrgUrl; Bot = $Bot }
        if ($ShareUserEmail) { $shareArgs.UserEmail = $ShareUserEmail } else { $shareArgs.Everyone = $true }
        & $share @shareArgs
    }

    Write-Step 'Done'
    Write-Host "  packed  $OutFile"
    if (-not $SkipImport) { Write-Host "  imported into $TargetOrgUrl" }
}
finally {
    if ($KeepWork) { Write-Host "`nwork kept at $work" }
    elseif (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
