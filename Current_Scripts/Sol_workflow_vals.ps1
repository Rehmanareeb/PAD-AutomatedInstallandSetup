
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Path,

    # literal = write the URLs straight in.  envvar = expose them as
    # environment variables the installer can set per environment.
    [ValidateSet('literal', 'envvar')]
    [string] $Mode = 'literal',

    [string] $SharePointUrl,
    [string] $OrgUrl,
    [string] $OutFile,

    [ValidateSet('Unmanaged', 'Managed', 'Both')]
    [string] $PackageType = 'Unmanaged',

    [switch] $ResolveLibraryId,

    # Library to resolve. Defaults to the one the flow already writes into,
    # taken from its folderPath (e.g. '/Shared Documents/Test Cases').
    [string] $Library,

    # keep the unpacked folder here instead of a temp dir (handy for diffing)
    [string] $KeepSource
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$EvSharePoint = 'cre44_SharePointSiteUrl'
$EvOrg        = 'cre44_DataverseOrgUrl'
$EvLibrary    = 'cre44_SharePointLibraryId'

$changes  = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Resolve-Pac {
    foreach ($n in 'pac', 'pac.cmd', 'pac.exe') {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    $candidates = @(
        "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\pac.cmd"
        "$env:USERPROFILE\.dotnet\tools\pac.exe"
        "${env:ProgramFiles}\Microsoft Power Platform CLI\pac.exe"
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    throw "pac (Power Platform CLI) not found. Install it with: winget install Microsoft.PowerPlatformCLI"
}
$pac = Resolve-Pac

function Resolve-SharePointLibraryId {

    param([string] $SiteUrl, [string] $LibraryName)

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) not found, needed by -ResolveLibraryId. Install it, or drop the switch and set the library id by hand.'
    }
    $token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "az could not get a Microsoft Graph token. Run 'az login' as an account that can read the target site.`n$token"
    }
    $h = @{ Authorization = "Bearer $token"; Accept = 'application/json' }

    $u = [uri] $SiteUrl
    try {
        $site = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$($u.Host):$($u.AbsolutePath)" -Headers $h
    }
    catch {
        throw "Could not read site $SiteUrl via Graph: $($_.Exception.Message). Check the URL and that this account has access."
    }

    $lists = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/lists?`$select=id,displayName,name" -Headers $h
    # 'name' is the URL segment ('Shared Documents'), 'displayName' the title ('Documents')
    $hit = @($lists.value | Where-Object { $_.name -eq $LibraryName -or $_.displayName -eq $LibraryName })

    if ($hit.Count -eq 0) {
        throw ("No library '$LibraryName' on $SiteUrl. Available:`n" +
               (($lists.value | ForEach-Object { "    $($_.displayName)  (url: $($_.name))" }) -join "`n"))
    }
    if ($hit.Count -gt 1) { throw "'$LibraryName' matches $($hit.Count) lists on $SiteUrl." }
    return $hit[0].id
}

# --- resolve input ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Not a file: $Path" }
$src = (Resolve-Path -LiteralPath $Path).Path

# --- prompt for values --------------------------------------------------------
if (-not $SharePointUrl) {
    $SharePointUrl = Read-Host 'SharePoint site URL  (e.g. https://contoso.sharepoint.com/sites/AICOE)'
}
if (-not $OrgUrl) {
    $OrgUrl = Read-Host 'Dataverse org URL    (e.g. https://org12345.crm.dynamics.com)'
}

$SharePointUrl = $SharePointUrl.Trim().TrimEnd('/')
$OrgUrl        = $OrgUrl.Trim().TrimEnd('/')

if ($SharePointUrl -notmatch '^https://[^/]+\.sharepoint\.com/sites/.+') {
    throw "SharePoint URL should look like https://<tenant>.sharepoint.com/sites/<site>"
}
if ($OrgUrl -notmatch '^https://[^/]+\.dynamics\.com$') {
    throw "Dataverse org URL should look like https://<org>.crm.dynamics.com"
}

# --- work out the output name: <OriginalName>_Changed.zip ---------------------
if (-not $OutFile) {
    $base    = [IO.Path]::GetFileNameWithoutExtension($src)
    $OutFile = Join-Path (Split-Path -Parent $src) "${base}_Changed.zip"
}

# --- unpack -------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("prepsol_" + [Guid]::NewGuid().ToString('N'))
$work = if ($KeepSource) { $KeepSource } else { Join-Path $tmp 'src' }
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }

try {
    & $pac solution unpack --zipfile $src --folder $work --packagetype $PackageType
    if ($LASTEXITCODE -ne 0) { throw "pac solution unpack failed (exit $LASTEXITCODE)" }
    Write-Host "unpacked $((Get-ChildItem -LiteralPath $work -Recurse -File).Count) files"

    $flow = @(Get-ChildItem -LiteralPath (Join-Path $work 'Workflows') -Filter 'Save-Generated-CSV-To-SharePoint-*.json' -File)
    if ($flow.Count -ne 1) { throw "Expected exactly one Agent-1 CSV flow, found $($flow.Count)" }
    $flowPath = $flow[0].FullName

    $json = Get-Content -LiteralPath $flowPath -Raw | ConvertFrom-Json
    $defn = $json.properties.definition

    function Add-FlowParameter {
        <# Declare an environment variable on the flow definition and return the
           expression that references it. #>
        param($Definition, [string] $Name, [string] $Value)

        $key  = "$Name ($Name)"
        $decl = [pscustomobject]@{
            defaultValue = $Value
            type         = 'String'
            metadata     = [pscustomobject]@{ schemaName = $Name }
        }
        if ($Definition.parameters.PSObject.Properties.Name -contains $key) {
            $Definition.parameters.$key = $decl
        }
        else {
            $Definition.parameters | Add-Member -NotePropertyName $key -NotePropertyValue $decl
        }
        return "@parameters('$key')"
    }

    if ($Mode -eq 'envvar') {
        $siteValue = Add-FlowParameter -Definition $defn -Name $EvSharePoint -Value $SharePointUrl
    }
    else {
        # literal is the inverse of envvar: drop any environment variable
        # declarations so re-running over an envvar package comes out clean
        $siteValue = $SharePointUrl
        foreach ($p in @($defn.parameters.PSObject.Properties.Name | Where-Object { $_ -notlike '$*' })) {
            $defn.parameters.PSObject.Properties.Remove($p)
        }
    }

    $n = 0
    $tableParams = @()
    $folderHint  = $null
    foreach ($actionName in $defn.actions.PSObject.Properties.Name) {
        $action = $defn.actions.$actionName
        $inputs = $action.inputs
        # Compose actions carry a plain string in .inputs, not an object
        if ($inputs -is [string] -or $null -eq $inputs) { continue }
        if ($inputs.PSObject.Properties.Name -notcontains 'parameters') { continue }
        $p     = $inputs.parameters
        $names = $p.PSObject.Properties.Name

        # remember the library the flow writes into, e.g. '/Shared Documents/Test Cases'
        if (-not $folderHint -and $names -contains 'folderPath' -and
            $p.folderPath -is [string] -and $p.folderPath.StartsWith('/')) {
            $folderHint = $p.folderPath
        }
        if ($names -contains 'table') { $tableParams += $p }

        if ($names -notcontains 'dataset') { continue }
        $cur = $p.dataset
        # match either form we may have written before
        if ($cur -is [string] -and ($cur -like '*sharepoint.com*' -or $cur -like '@parameters(*')) {
            $p.dataset = $siteValue
            $n++
        }
    }
    if ($n -eq 0) { throw "No SharePoint dataset values found in $($flow[0].Name)" }


    $libEnvDef = $null
    if ($tableParams.Count) {
        if ($ResolveLibraryId) {
            $libName =
                if ($Library)    { $Library }
                elseif ($folderHint) { ($folderHint.Trim('/') -split '/')[0] }
                else             { 'Shared Documents' }

            $libId = Resolve-SharePointLibraryId -SiteUrl $SharePointUrl -LibraryName $libName
            $changes.Add("library: resolved '$libName' on the target site -> $libId")

            $tableValue = $libId
            if ($Mode -eq 'envvar') {
                $tableValue = Add-FlowParameter -Definition $defn -Name $EvLibrary -Value $libId
                $libEnvDef  = @{ Name = $EvLibrary; Value = $libId; Display = 'SharePoint Library Id' }
            }
            foreach ($tp in $tableParams) { $tp.table = $tableValue }
            $changes.Add("flow: set $($tableParams.Count) library id value(s)")
        }
        else {
            foreach ($tp in $tableParams) {
                if ($tp.table -is [string] -and
                    $tp.table -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    $warnings.Add("flow: 'table' is the library GUID $($tp.table), which belongs to whichever site this was exported from. Re-run with -ResolveLibraryId to look up the right one for $SharePointUrl.")
                }
            }
        }
    }

    ($json | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $flowPath -Encoding utf8NoBOM
    $changes.Add("flow: set $n SharePoint site value(s) in $($flow[0].Name)")


    function Set-ToolInput {
   

        param([string] $File, [string] $Prop, [string] $Value)

        $lines    = [System.IO.File]::ReadAllLines($File)
        $inInputs = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^inputs:\s*$') { $inInputs = $true; continue }
            if ($inInputs -and $lines[$i] -match '^\S') { break }   # next top-level key
            if ($inInputs -and $lines[$i] -match ("^\s*propertyName:\s*" + [regex]::Escape($Prop) + "\s*$")) {
                for ($j = $i + 1; $j -lt [Math]::Min($i + 4, $lines.Count); $j++) {
                    if ($lines[$j] -match '^(\s*)value:\s*.*$') {
                        $lines[$j] = "$($Matches[1])value: $Value"
                        [System.IO.File]::WriteAllLines($File, $lines)
                        return $true
                    }
                }
                break
            }
        }
        return $false
    }

    $tools = @(
        @{ Glob = '*Agent1TestScript.action.SharePoint-Createfile'
           Prop = 'dataset';      Literal = $SharePointUrl; Ev = $EvSharePoint; Label = 'SharePoint file tool' }
        @{ Glob = '*Agent1TestScript.action.MicrosoftDataverse-Addanewrowtoselectedenvironment'
           Prop = 'organization'; Literal = $OrgUrl;        Ev = $EvOrg;        Label = 'Dataverse row tool' }
    )

    $evLinks = @()
    foreach ($t in $tools) {
        $dir = @(Get-ChildItem -LiteralPath (Join-Path $work 'botcomponents') -Filter $t.Glob -Directory)
        if ($dir.Count -ne 1) { throw "Expected exactly one $($t.Label), found $($dir.Count)" }
        $dataFile = Join-Path $dir[0].FullName 'data'
        $value = if ($Mode -eq 'envvar') { "=Env.$($t.Ev)" } else { $t.Literal }

        if (Set-ToolInput -File $dataFile -Prop $t.Prop -Value $value) {
            $changes.Add("tool: set '$($t.Prop)' in $($t.Label)")
            if ($Mode -eq 'envvar') { $evLinks += @{ Component = $dir[0].Name; Ev = $t.Ev } }
        }
        else {
            $warnings.Add("could not find '$($t.Prop)' input in $($t.Label) - left unchanged")
        }
    }

    if ($Mode -eq 'envvar') {
        $defs = @(
            @{ Name = $EvSharePoint; Value = $SharePointUrl; Display = 'SharePoint Site URL' }
            @{ Name = $EvOrg;        Value = $OrgUrl;        Display = 'Dataverse Org URL' }
        )
        # only present when -ResolveLibraryId actually looked one up
        if ($libEnvDef) { $defs += $libEnvDef }
        foreach ($d in $defs) {
            $dir = Join-Path $work "environmentvariabledefinitions\$($d.Name)"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $xml = @"
<environmentvariabledefinition schemaname="$($d.Name)">
  <defaultvalue>$($d.Value)</defaultvalue>
  <displayname default="$($d.Display)">
    <label description="$($d.Display)" languagecode="1033" />
  </displayname>
  <introducedversion>1.0.0.0</introducedversion>
  <iscustomizable>1</iscustomizable>
  <isrequired>1</isrequired>
  <secretstore>0</secretstore>
  <type>100000000</type>
</environmentvariabledefinition>
"@
            Set-Content -LiteralPath (Join-Path $dir 'environmentvariabledefinition.xml') -Value $xml -Encoding utf8NoBOM
            $changes.Add("env var: defined $($d.Name)")
        }

        # link the tools to their variable, same shape as the cre44_FnoPassword
        # link already present in this solution
        $linkFile = Join-Path $work 'Assets\botcomponent_environmentvariabledefinitionset.xml'
        # Solutions with no env-var-using component yet have no link file at all
        # (the 1_0_0_8 lineage is like this), so start one.
        if ($evLinks.Count -and -not (Test-Path -LiteralPath $linkFile)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $linkFile) -Force | Out-Null
            Set-Content -LiteralPath $linkFile -Encoding utf8NoBOM `
                -Value "<botcomponent_environmentvariabledefinitionset>`n</botcomponent_environmentvariabledefinitionset>"
            $changes.Add('env var: created the botcomponent link file (none existed)')
        }
        if ($evLinks.Count -and (Test-Path -LiteralPath $linkFile)) {
            $x = Get-Content -LiteralPath $linkFile -Raw
            $rows = ''
            foreach ($l in $evLinks) {
                if ($x -match [regex]::Escape("environmentvariabledefinitionid.schemaname=`"$($l.Ev)`"")) { continue }
                $rows += "  <botcomponent_environmentvariabledefinition botcomponentid.schemaname=`"$($l.Component)`" environmentvariabledefinitionid.schemaname=`"$($l.Ev)`">`n"
                $rows += "    <iscustomizable>1</iscustomizable>`n"
                $rows += "  </botcomponent_environmentvariabledefinition>`n"
            }
            if ($rows) {
                $x = $x -replace '</botcomponent_environmentvariabledefinitionset>', ($rows + '</botcomponent_environmentvariabledefinitionset>')
                Set-Content -LiteralPath $linkFile -Value $x -Encoding utf8NoBOM
                $changes.Add("env var: linked $($evLinks.Count) agent tool(s)")
            }
        }
        elseif ($evLinks.Count) {
            $warnings.Add('Assets\botcomponent_environmentvariabledefinitionset.xml missing - tools not linked')
        }
    }


    $cust = @(
        (Join-Path $work 'Other\Customizations.xml')
        (Join-Path $work 'customizations.xml')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    $shipped = @()
    if ($cust) {
        $ctext = Get-Content -LiteralPath $cust -Raw
        $shipped = [regex]::Matches($ctext, '(?s)<AppModule>.*?<UniqueName>(.*?)</UniqueName>') |
                   ForEach-Object { $_.Groups[1].Value }
    }
    else {
        $warnings.Add('customizations manifest not found - assuming no app modules are shipped')
    }

    $searchRoot = Join-Path $work 'dvtablesearchs'
    $removedAny = $false
    if (Test-Path -LiteralPath $searchRoot) {
        foreach ($sf in Get-ChildItem -LiteralPath $searchRoot -Recurse -Filter 'dvtablesearch.xml' -File) {
            $sx = Get-Content -LiteralPath $sf.FullName -Raw
            $m = [regex]::Match($sx, '(?s)<m365appmoduleid>\s*<uniquename>(.*?)</uniquename>')
            if (-not $m.Success) { continue }
            $app = $m.Groups[1].Value
            if ($shipped -contains $app) { continue }

            $folder   = $sf.Directory
            $searchId = $folder.Name

            $entRoot = Join-Path $work 'dvtablesearchentities'
            if (Test-Path -LiteralPath $entRoot) {
                foreach ($ef in Get-ChildItem -LiteralPath $entRoot -Recurse -Filter 'dvtablesearchentity.xml' -File) {
                    if ((Get-Content -LiteralPath $ef.FullName -Raw) -match [regex]::Escape($searchId)) {
                        Remove-Item -LiteralPath $ef.Directory.FullName -Recurse -Force
                    }
                }
            }
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force

            $dvLink = Join-Path $work 'Assets\botcomponent_dvtablesearchset.xml'
            if (Test-Path -LiteralPath $dvLink) {
                $lx = Get-Content -LiteralPath $dvLink -Raw
                $nx = [regex]::Replace($lx,
                    '(?is)\s*<botcomponent_dvtablesearch[^>]*' + [regex]::Escape($searchId) + '.*?</botcomponent_dvtablesearch>', '')
                if ($nx -ne $lx) { Set-Content -LiteralPath $dvLink -Value $nx -Encoding utf8NoBOM }
            }

            $changes.Add("import fix: removed search config for missing app '$app'")
            $removedAny = $true
        }
    }
    if (-not $removedAny) { $changes.Add('import fix: nothing to remove (no orphaned app search config)') }


    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
    & $pac solution pack --zipfile $OutFile --folder $work --packagetype $PackageType
    if ($LASTEXITCODE -ne 0) { throw "pac solution pack failed (exit $LASTEXITCODE)" }

    Write-Host ''
    $changes  | ForEach-Object { Write-Host "  - $_" }
    $warnings | ForEach-Object { Write-Warning $_ }
    Write-Host ''
    Write-Host "wrote $OutFile"
    if ($KeepSource) { Write-Host "unpacked source kept at $work" }
    Write-Host "mode: $Mode"
    if ($Mode -eq 'envvar') {
        Write-Host 'NOTE: open the flow in the designer after import and confirm the'
        Write-Host '      SharePoint site field resolves to the environment variable.'
    }
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
