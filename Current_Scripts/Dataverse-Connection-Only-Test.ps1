<#
.SYNOPSIS
  Binds the solution's connection references to real connections in the target
  environment, so an import comes up connected instead of half-configured.

.DESCRIPTION
  Copilot Studio writes one connection reference per agent tool. For this
  solution that is a Dataverse one and a SharePoint one, both used by Agent 1:

      cr720_Agent1TestScript.shared_commondataserviceforapps.shared-commondataser-...
      cr720_Agent1TestScript.shared_sharepointonline.shared-sharepointonl-...

  Those references arrive at the target environment empty. Nothing in the
  solution carries a connection id, because a connection is per-environment and
  per-user - it cannot travel inside a zip. Until each reference is pointed at a
  connection that exists in the target, the agent's tools fail at run time.

  Platform already has the binding mechanism: the deployment settings file that
  `pac solution import --settings-file` consumes. What it does not have is a way
  to fill that file in. That is all this script is:

      1. pac solution create-settings   lists every reference, ids blank
      2. pac connection list            what actually exists in the target
      3. match by connector, fill in the ids
      4. pac solution import --settings-file   with -Import

  Matching is by connector id. One connection for a connector is taken silently.
  Several - and this tenant has six SharePoint connections - is an ambiguity the
  script refuses to guess at: it prompts, or takes a -Connection override so the
  run stays unattended.

  Dataverse can also be created here, with -CreateDataverse. That connector
  publishes a ServicePrincipalOauth parameter set, so a client id, secret and
  tenant id are enough - no human, no consent screen.

  SharePoint cannot, and this is a platform limit rather than a gap in the
  script. Ask the connector what it accepts and shared_sharepointonline offers
  no parameter sets at all: one `token` of type oauthSetting carrying
  capability 'cloud', and username/password only under capability 'gateway',
  which is on-premises SharePoint Server through a data gateway, not SharePoint
  Online. So the first SharePoint connection in each new environment needs a
  person to sign in once at make.powerapps.com. After that its id is reusable
  forever and every later run is unattended.

.PARAMETER SolutionZip
  The packed solution to read the references from. Either this or -SolutionFolder.

.PARAMETER SolutionFolder
  An unpacked solution folder - the one holding Other\Solution.xml.

.PARAMETER EnvironmentUrl
  Target environment, e.g. https://org59029660.crm.dynamics.com

  REQUIRED. Prompted for when omitted rather than failing, and validated: this
  URL is written into the agent tool's own data file, so pointing it at the wrong
  environment ships a tool that calls somewhere else while every step still
  reports success. The scheme may be left off and a trailing slash is fine;
  regional hosts (crm4, crm11, ...) are accepted.

.PARAMETER SettingsFile
  Where to write the deployment settings. Defaults to .\deploy-settings.json.

.PARAMETER Connection
  Pins a connector to a connection id, 'connector=id', comma separated. Use it
  to keep the run unattended where more than one connection would match:

      -Connection shared_sharepointonline=shared-sharepointonl-25624ec1-...,shared_commondataserviceforapps=shared-commondataser-596d802d-...

.PARAMETER CreateDataverse
  Create a Dataverse connection with a service principal before binding, and use
  it. Needs -AppId and -TenantId, and the secret in $env:PP_CLIENT_SECRET so it
  never lands on a command line or in shell history. Requires `az login`.

.PARAMETER AppId
  Client id of the app registration the Dataverse connection signs in as. That
  app must already be an application user in the target environment.

.PARAMETER TenantId
  Tenant of that app registration.

.PARAMETER EnvironmentId
  Environment GUID, only needed by -CreateDataverse. Looked up from
  -EnvironmentUrl when omitted.

.PARAMETER UseConnection
  Bind the Dataverse reference to a connection that already exists, instead of
  creating one. Takes the DISPLAY NAME you see in make.powerapps.com, or the id
  if you have it - both work.

  Supplying it turns off connection creation, including under -DataverseOnly,
  which otherwise always creates one.

      -UseConnection 'Testing from front 3'
      -UseConnection f7ca37d13cff420ab11decd6304c71f0

.PARAMETER NewConnectionName
  Display name for the connection -CreateDataverse makes. Default 'dataverse-sp'.

.PARAMETER CreateSharePoint
  Create a SharePoint connection before binding, and use it. Opens a browser for
  one sign-in - SharePoint has no service principal option - then polls until
  the connection reports Connected. Requires `az login`.

.PARAMETER SharePointConnectionName
  Display name for that connection. Default 'sharepoint-oauth'.

.PARAMETER ConsentTimeoutSeconds
  How long to wait for that sign-in. Default 300.

.PARAMETER Import
  Import the solution with the finished settings file. Without it the file is
  written and nothing touches the environment.

.EXAMPLE
  .\Set-SolutionConnections.ps1 -SolutionFolder C:\...\Explore_Connection_Solution `
                                -EnvironmentUrl https://org59029660.crm.dynamics.com

  Write deploy-settings.json, prompting where a connector is ambiguous.

.EXAMPLE
  .\Set-SolutionConnections.ps1 -SolutionZip .\Solution_Changed.zip `
      -EnvironmentUrl https://org59029660.crm.dynamics.com `
      -Connection shared_sharepointonline=shared-sharepointonl-25624ec1-8ab0-41b9-bdad-6c480a8be8ab,shared_commondataserviceforapps=shared-commondataser-596d802d-0a48-40a0-80e0-b4731da0349c `
      -Import

  Fully unattended: bind both of Agent 1's connectors and import.
#>
[CmdletBinding()]
param(
    [string]   $SolutionZip,
    [string]   $SolutionFolder,
    [string]   $EnvironmentUrl,
    [string]   $SettingsFile,
    [string[]] $Connection = @(),
    [switch]   $CreateDataverse,
    [string]   $AppId,
    [string]   $TenantId,
    [string]   $EnvironmentId,
    [string]   $NewConnectionName = 'dataverse-sp',
    [switch]   $CreateSharePoint,
    [string]   $SharePointConnectionName = 'sharepoint-oauth',
    [int]      $ConsentTimeoutSeconds = 300,
    [switch]   $DataverseOnly,
    [string]   $UseConnection,
    [string]   $DataFilePath = 'botcomponents/cr720_Agent1TestScript.action.MicrosoftDataverse-Addanewrowtoselectedenvironment/data',
    [switch]   $Import,
    [switch]   $SelfTest,
    [switch]   $Help
)

if ($Help) { Get-Help $PSCommandPath -Detailed; return }

function Write-Log($m)     { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" }

if ($DataverseOnly) {
    $CreateSharePoint = $false
    if ($UseConnection) {
        # Use what is already there instead of making another one. Without this,
        # -DataverseOnly always creates, and there is no way to point the run at
        # a connection that already works.
        $CreateDataverse = $false
        Write-Log "Dataverse-only mode. Using the existing connection '$UseConnection' - none will be created."
    }
    else {
        $CreateDataverse = $true
        Write-Log 'Dataverse-only mode enabled. Non-Dataverse creation and binding will be skipped.'
    }
}
elseif ($UseConnection) {
    $CreateDataverse = $false
}

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Write-Section($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# `pac connection list` prints a fixed-width table, and a connection name may
# contain spaces ("Hosted browser") while the id, connector and status never do.
# So read the columns in from both ends and let the name be whatever is left.

function Invoke-Pac {
    <#
      Two things pac needs wrapping for.

      It exits 0 even when it printed an error - an unknown argument, a failed
      pack, a bad path all come back "successful". Trusting $LASTEXITCODE alone
      turns "you passed a flag that does not exist" into a silent no-op that only
      surfaces later as a missing file. So read the output and treat an Error:
      line as the failure it is.

      And a solution zip under Desktop is contended: OneDrive and Defender both
      take a handle the moment it is written, so the NEXT pac call can fail with
      a sharing violation on a file this script created a moment earlier. That
      clears on its own in a second or two, so it is retried rather than fatal.
    #>
    param(
        [Parameter(Mandatory=$true)][string[]] $Arguments,
        [int] $RetryOnBusy = 4
    )

    for ($attempt = 1; ; $attempt++) {
        $out = & pac @Arguments 2>&1 | ForEach-Object { "$_" }
        $out | ForEach-Object { Write-Host "  $_" }

        $errs = @($out | Where-Object { $_ -match '^\s*Error:' })
        if ($LASTEXITCODE -eq 0 -and -not $errs.Count) { return }

        $busy = @($errs | Where-Object {
            $_ -match 'being used by another process|access to the path .* is denied|The process cannot access the file' })

        if ($busy.Count -and $attempt -le $RetryOnBusy) {
            Write-Log "  file is busy (OneDrive or Defender, usually). Retry $attempt of $RetryOnBusy in 2s."
            Start-Sleep -Seconds 2
            continue
        }

        $code = if ($LASTEXITCODE -ne 0) { " (exit $LASTEXITCODE)" } else { '' }
        $hint = if ($busy.Count) {
            "`n  Still locked after $RetryOnBusy retries. Pause OneDrive sync on that folder, or work outside Desktop."
        } else { '' }
        throw ("pac $($Arguments -join ' ') failed$code" +
               $(if ($errs.Count) { ":`n  " + ($errs -join "`n  ") } else { '.' }) + $hint)
    }
}

function Ensure-DataverseConnectionReferenceInSolution {
    param(
        [Parameter(Mandatory=$true)][string] $SolutionZip,
        [Parameter(Mandatory=$true)][string] $EnvironmentUrl,
        [string] $DataRelativePath = 'botcomponents/cr720_Agent1TestScript.action.MicrosoftDataverse-Addanewrowtoselectedenvironment/data',
        [string] $PreferredLogicalName = 'cr_auto_dataverse_connectionreference'
    )

    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        throw 'Power Platform CLI (pac) was not found on PATH. Install pac CLI and run this script from a terminal where pac is available.'
    }

    if (-not (Test-Path -LiteralPath $SolutionZip -PathType Leaf)) {
        throw "Solution ZIP was not found: $SolutionZip"
    }

    $solutionZipFull = (Resolve-Path -LiteralPath $SolutionZip).Path
    $solutionFolder = Join-Path ([IO.Path]::GetTempPath()) ("solution-pac-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $solutionFolder -Force | Out-Null

    try {
        Write-Log "Unpacking solution with pac CLI: $solutionZipFull"
        Invoke-Pac @('solution', 'unpack', '--zipfile', $solutionZipFull, '--folder', $solutionFolder, '--allowDelete', '--clobber')

        # PAC CLI may unpack Customizations.xml under a subfolder such as
        # Other\Customizations.xml. Search recursively and accept either casing.
        $customizationsPath = Get-ChildItem `
            -LiteralPath $solutionFolder `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq 'customizations.xml' } |
            Select-Object -First 1 -ExpandProperty FullName

        if (-not $customizationsPath) {
            $unpackedFiles = Get-ChildItem `
                -LiteralPath $solutionFolder `
                -Recurse `
                -File `
                -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName

            $fileList = ($unpackedFiles -join [Environment]::NewLine)

            throw "Could not find Customizations.xml anywhere after pac unpack. Unpacked files:`n$fileList"
        }

        Write-Log "Using customizations file: $customizationsPath"

        <#
          Refuse an EMPTY export before doing anything with it.

          An agent added to a solution the wrong way exports as three files -
          solution.xml, customizations.xml, [Content_Types].xml - about 1.6 KB,
          zero RootComponents, no botcomponents. Everything downstream still
          "succeeds": it packs, create-settings finds no references, the import
          lands a solution with nothing in it.

          Deliberately NOT checking that the agent appears in RootComponents.
          Copilot Studio agents are not declared there - CUAExecutionValidator
          carries two agents and lists neither, its only bot-ish RootComponents
          (types 62 and 80) being the app module and its sitemap - and it imports
          its agents correctly. A check on that basis rejects good packages.
        #>
        $botDirs = @(Get-ChildItem -LiteralPath (Join-Path $solutionFolder 'botcomponents') -Directory -ErrorAction SilentlyContinue)
        $solutionXml = Get-ChildItem -LiteralPath $solutionFolder -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq 'solution.xml' } | Select-Object -First 1 -ExpandProperty FullName
        if (-not $solutionXml) { throw "Could not find Solution.xml after unpack in $solutionFolder." }

        $rootCount = ([regex]::Matches((Get-Content -LiteralPath $solutionXml -Raw), '<RootComponent\b')).Count
        Write-Log "Package holds $($botDirs.Count) bot component(s) and $rootCount RootComponent(s)."

        if ($rootCount -eq 0 -and $botDirs.Count -eq 0) {
            throw @"
This solution is EMPTY - no RootComponents and no bot components.

Nothing downstream will notice: it packs, create-settings finds no references,
and the import lands a solution containing nothing.

The export is the problem. In make.powerapps.com -> Solutions -> your solution,
use 'Add existing' to put the agent in, then export again. A real export of this
agent is tens of KB with a botcomponents folder, not ~1.6 KB with three files.
"@
        }

        [xml]$customizations = Get-Content -LiteralPath $customizationsPath -Raw
        $root = $customizations.ImportExportXml
        if (-not $root) { throw 'customizations.xml does not contain ImportExportXml.' }

        $dvConnector = '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps'

        <#
          SelectSingleNode / SelectNodes rather than $root.connectionreferences.

          PowerShell adapts XML: for an element with no CHILD ELEMENTS,
          $node.childName hands back the inner TEXT - a [string] - instead of the
          element. So on a solution whose <connectionreferences/> is empty,
          $root.connectionreferences is a string: the reference search silently
          finds nothing, and the AppendChild below fails with "[System.String]
          does not contain a method named 'AppendChild'". The DOM calls return an
          XmlNode or $null and never do that.
        #>
        $refsNode = $root.SelectSingleNode('connectionreferences')
        $existing = @()
        if ($refsNode) {
            $existing = @($refsNode.SelectNodes('connectionreference') |
                Where-Object { $_.connectorid -eq $dvConnector })
        }

        # The tool this run is about, taken from -DataFilePath
        # (botcomponents/<schema>/data) rather than hard-coded a second time.
        $toolSchema  = (($DataRelativePath -replace '\\', '/') -split '/')[-2]
        $agentPrefix = ($toolSchema -split '\.')[0]

        $logicalName = $null
        if ($existing.Count -gt 0) {
            # Prefer the reference Copilot Studio generated for THIS agent.
            # $existing[0] is whichever Dataverse reference happens to come first
            # in customizations.xml - in this solution that is the FLOWS' one
            # (copilots_header_...), not the agent's, and binding the agent's
            # tool to it is silently wrong.
            $mine = @($existing | Where-Object { $_.connectionreferencelogicalname -like "$agentPrefix.*" })
            $logicalName = if ($mine.Count) {
                [string]$mine[0].connectionreferencelogicalname
            } else {
                [string]$existing[0].connectionreferencelogicalname
            }
            Write-Log "A Dataverse connection reference already exists: $logicalName"
        }
        else {
            if (-not $refsNode) {
                $refsNode = $customizations.CreateElement('connectionreferences')
                [void]$root.AppendChild($refsNode)
            }

            $logicalName = $PreferredLogicalName
            $suffix = 1
            while (@($refsNode.SelectNodes('connectionreference') |
                    Where-Object { $_.connectionreferencelogicalname -eq $logicalName }).Count -gt 0) {
                $logicalName = "$PreferredLogicalName$suffix"
                $suffix++
            }

            $ref = $customizations.CreateElement('connectionreference')
            $ref.SetAttribute('connectionreferencelogicalname', $logicalName)

            foreach ($pair in @{
                connectionreferencedisplayname = 'Dataverse'
                connectorid = $dvConnector
                iscustomizable = '1'
                promptingbehavior = '0'
                statecode = '0'
                statuscode = '1'
            }.GetEnumerator()) {
                $child = $customizations.CreateElement($pair.Key)
                $child.InnerText = $pair.Value
                [void]$ref.AppendChild($child)
            }

            [void]$refsNode.AppendChild($ref)
            $customizations.Save($customizationsPath)
            Write-Log "Created Dataverse connection reference '$logicalName' in customizations.xml."
        }

        # Update the Copilot Studio bot-component connection-reference set, if present.
        $setPath = Get-ChildItem -LiteralPath $solutionFolder -Filter 'botcomponent_connectionreferenceset.xml' -Recurse -File |
            Select-Object -First 1 -ExpandProperty FullName

        if ($setPath) {
            [xml]$setXml = Get-Content -LiteralPath $setPath -Raw
            $setRoot = $setXml.DocumentElement

            # Ask whether THE TOOL already has a mapping, not whether this
            # reference appears anywhere. Keying off the reference adds a second
            # entry for a tool that is already mapped, and a tool claimed by two
            # connection references is not something the designer handles well.
            # SelectNodes for the same reason as above - an empty set element
            # would otherwise adapt to a string.
            $alreadyInSet = @($setRoot.SelectNodes('botcomponent_connectionreference') |
                Where-Object { $_.'botcomponentid.schemaname' -eq $toolSchema })

            if ($alreadyInSet.Count) {
                $bound = [string]$alreadyInSet[0].'connectionreferenceid.connectionreferencelogicalname'
                Write-Log "Tool '$toolSchema' is already mapped to '$bound' - leaving it as it is."
            }

            if ($alreadyInSet.Count -eq 0) {
                $entry = $setXml.CreateElement('botcomponent_connectionreference')
                $entry.SetAttribute('botcomponentid.schemaname', $toolSchema)
                $entry.SetAttribute(
                    'connectionreferenceid.connectionreferencelogicalname',
                    $logicalName
                )
                $customizable = $setXml.CreateElement('iscustomizable')
                $customizable.InnerText = '1'
                [void]$entry.AppendChild($customizable)
                [void]$setRoot.AppendChild($entry)
                $setXml.Save($setPath)
                Write-Log "Added Dataverse reference '$logicalName' to botcomponent_connectionreferenceset.xml."
            }
        }

        # Update the organization URL in the requested bot-component data file.
        $dataPath = Join-Path $solutionFolder ($DataRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $dataPath -PathType Leaf) {
            $dataText = Get-Content -LiteralPath $dataPath -Raw
            $orgPattern = '(?m)(propertyName:\s*organization\s*\r?\n\s*value:\s*)https?://[^\s]+'
            $replacement = '$1' + $EnvironmentUrl.TrimEnd('/')
            $updatedDataText = [regex]::Replace($dataText, $orgPattern, $replacement)

            if ($updatedDataText -ne $dataText) {
                Set-Content -LiteralPath $dataPath -Value $updatedDataText -Encoding UTF8
                Write-Log "Updated organization URL in: $DataRelativePath"
            }
            else {
                Write-Log "No organization URL was changed in: $DataRelativePath"
            }
        }
        else {
            Write-Log "Data file was not found after unpacking; skipping URL update: $dataPath"
        }

        # Keep the original ZIP untouched and create a new output ZIP.
        $solutionDirectory = Split-Path -Parent $solutionZipFull
        $solutionBaseName = [System.IO.Path]::GetFileNameWithoutExtension($solutionZipFull)
        $outputZipName = "${solutionBaseName}_Dataverse_Con.zip"
        $outputZipPath = Join-Path -Path $solutionDirectory -ChildPath $outputZipName

        Write-Log "Original solution ZIP: $solutionZipFull"
        Write-Log "New output solution ZIP: $outputZipPath"

        Write-Log "Packing modified solution with pac CLI"

        <#
          Pack to a temp file, then move it into place - do not let pac write the
          destination directly.

          The output sits under Desktop, where OneDrive and Defender both take a
          handle the moment a file appears. pac loses that race with "The process
          cannot access the file because it is being used by another process",
          and leaves a TRUNCATED zip behind - a ~1.8 KB stub that still opens
          like an archive, so the next step reads garbage rather than failing.

          Staging keeps the pack itself away from the contended path, and the
          move is retried, so a transient hold costs a second instead of the run.

          --packagetype, not --zipFileType: there is no --zipFileType on
          `pac solution pack`, and passing it makes pac print "An unknown
          argument was passed" and then exit 0.
        #>
        $stagedZip = Join-Path ([IO.Path]::GetTempPath()) `
                               ('pack-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')

        Invoke-Pac @('solution', 'pack', '--folder', $solutionFolder, '--zipfile', $stagedZip, '--packagetype', 'Unmanaged')

        if (-not (Test-Path -LiteralPath $stagedZip -PathType Leaf)) {
            throw "pac solution pack reported success but did not create: $stagedZip"
        }

        $moved = $false
        foreach ($attempt in 1..5) {
            try {
                Move-Item -LiteralPath $stagedZip -Destination $outputZipPath -Force -ErrorAction Stop
                $moved = $true
                break
            }
            catch {
                Write-Log "  destination busy (attempt $attempt of 5): $($_.Exception.Message)"
                Start-Sleep -Seconds 2
            }
        }

        if (-not $moved) {
            throw ("Could not write $outputZipPath after 5 attempts - something is holding it open " +
                   "(OneDrive, Defender, or an archive tool with it open). " +
                   "The packed solution is intact at $stagedZip - move it across by hand, or close whatever has it and re-run.")
        }

        if (-not (Test-Path -LiteralPath $outputZipPath -PathType Leaf)) {
            throw "The move reported success but $outputZipPath is not there."
        }

        Write-Log "New solution ZIP created successfully: $outputZipPath"
        return $outputZipPath
    }
    finally {
        if (Test-Path -LiteralPath $solutionFolder) {
            Remove-Item -LiteralPath $solutionFolder -Recurse -Force
        }
    }
}

function Test-EnvironmentUrl {
    <#
      Is this an org URL? Accepts the regional hosts too - crm4, crm11 and the
      rest - and nothing else. Returns the normalised URL, or $null.
    #>
    param([string] $Value)
    $v = "$Value".Trim().TrimEnd('/')
    if (-not $v) { return $null }
    if ($v -notmatch '^[a-z][a-z0-9+.-]*://') { $v = "https://$v" }   # scheme is easy to leave off
    if ($v -match '^https://[^/]+\.crm[0-9]*\.dynamics\.com$') { return $v }
    $null
}

function Read-RequiredEnvironmentUrl {
    <#
      -EnvironmentUrl is required, and getting it wrong is quiet rather than
      loud: this URL is written into the agent tool's own data file, so the wrong
      environment ships a tool that points somewhere else, and every step after
      it still reports success. Worth insisting on, and worth validating the
      shape rather than taking any string.

      Prompts when it is missing instead of throwing, so an interactive run is
      not lost to one forgotten flag.
    #>
    param([string] $Value)

    $ok = Test-EnvironmentUrl $Value
    if ($ok) { return $ok }

    if ($Value) { Write-Host "  '$Value' is not an org URL." -ForegroundColor Yellow }
    while (-not $ok) {
        $entered = Read-Host 'Target environment URL (https://org<id>.crm.dynamics.com)'
        $ok = Test-EnvironmentUrl $entered
        if (-not $ok) {
            Write-Host "  Expected something like https://org65efd8ed.crm.dynamics.com - got '$entered'." -ForegroundColor Yellow
        }
    }
    $ok
}

function ConvertFrom-PacConnectionList {
    param([string[]] $Lines)
    $out = @()
    foreach ($line in $Lines) {
        $t = ($line -split '\s+') | Where-Object { $_ }
        if ($t.Count -lt 4) { continue }
        if ($t[-2] -notmatch '^/providers/Microsoft\.PowerApps/apis/') { continue }  # skips the header
        $out += [pscustomobject]@{
            Id        = $t[0]
            Connector = $t[-2] -replace '^.*/', ''
            Status    = $t[-1]
            Name      = ($t[1..($t.Count - 3)] -join ' ')
        }
    }
    $out
}

if ($SelfTest) {
    $rows = ConvertFrom-PacConnectionList @(
        'Id                        Name             API Id                                                       Status',
        'shared-sharepointonl-25   Demouser1@x.com  /providers/Microsoft.PowerApps/apis/shared_sharepointonline  Connected',
        '69f5e3e5258143            T14-GEN1 CUA     /providers/Microsoft.PowerApps/apis/shared_computeroperator  Connected',
        'Connected as somebody@example.com'
    )
    if ($rows.Count -ne 2)                        { throw "selftest: expected 2 rows, got $($rows.Count)" }
    if ($rows[0].Connector -ne 'shared_sharepointonline') { throw "selftest: connector was '$($rows[0].Connector)'" }
    if ($rows[1].Name      -ne 'T14-GEN1 CUA')    { throw "selftest: a name with a space was cut to '$($rows[1].Name)'" }
    if ($rows[0].Id        -ne 'shared-sharepointonl-25') { throw "selftest: id was '$($rows[0].Id)'" }

    foreach ($case in @(
        @{ In = 'https://org65efd8ed.crm.dynamics.com';  Want = 'https://org65efd8ed.crm.dynamics.com' }
        @{ In = 'https://org65efd8ed.crm.dynamics.com/'; Want = 'https://org65efd8ed.crm.dynamics.com' }  # trailing slash
        @{ In = '  org65efd8ed.crm.dynamics.com  ';      Want = 'https://org65efd8ed.crm.dynamics.com' }  # no scheme
        @{ In = 'https://org1.crm4.dynamics.com';        Want = 'https://org1.crm4.dynamics.com' }        # regional host
        @{ In = 'org65efd8ed.crm.dynamics.com/api/data'; Want = $null }                                   # a path is not an org url
        @{ In = 'https://contoso.sharepoint.com';        Want = $null }
        @{ In = 'not a url';                             Want = $null }
        @{ In = '';                                      Want = $null }
    )) {
        $got = Test-EnvironmentUrl $case.In
        if ($got -ne $case.Want) {
            throw "selftest: Test-EnvironmentUrl '$($case.In)' gave '$got', wanted '$($case.Want)'"
        }
    }

    'ok'
    return
}

if (-not $SolutionZip -and -not $SolutionFolder) { throw 'Pass -SolutionZip or -SolutionFolder.' }
if ($SolutionZip -and $SolutionFolder)           { throw 'Pass -SolutionZip or -SolutionFolder, not both.' }
$EnvironmentUrl = Read-RequiredEnvironmentUrl $EnvironmentUrl
if ($Import -and -not $SolutionZip) { throw '-Import needs -SolutionZip: a folder cannot be imported, pack it first.' }

if (-not $SettingsFile) { $SettingsFile = Join-Path (Get-Location).Path 'deploy-settings.json' }

$pac = (Get-Command pac, pac.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $pac) { $pac = "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\pac.cmd" }
if (-not (Test-Path $pac)) { throw 'pac not found - install from https://aka.ms/PowerAppsCLI' }

# 'connector=id' pairs, connector name normalised so shared_sharepointonline and
# the full /providers/... form both work.
# -File hands an array parameter through as one comma-joined string, so split it
# back. A connection id never contains a comma.
$Connection = @($Connection | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$pins = @{}
foreach ($c in $Connection) {
    if ($c -notmatch '^(.+?)=(.+)$') { throw "-Connection wants 'connector=id', got '$c'." }
    $pins[($Matches[1] -replace '^.*/', '').Trim()] = $Matches[2].Trim()
}

function Resolve-ConnectionName {
    <#
      -UseConnection takes what you can actually read in the portal: the display
      name. Connection ids are opaque 32-hex strings and copying one by hand is
      how the wrong connection gets bound.

      An id is passed straight through, so both forms work. A name is looked up
      among the CONNECTED connections for that connector, and an ambiguous or
      missing name lists what is really there rather than guessing.
    #>
    param([string] $Value, [string] $Connector, [string] $Pac, [string] $EnvironmentUrl)

    # ids come in two shapes: bare 32-hex, and the portal's 'shared-xxxx-<guid>'
    if ($Value -match '^[0-9a-fA-F]{32}$' -or $Value -match '^shared-[a-z0-9]+-[0-9a-fA-F-]{36}$') {
        Write-Log "Using connection id $Value"
        return $Value
    }

    $listed = & $Pac connection list --environment $EnvironmentUrl 2>&1 | ForEach-Object { "$_" }
    $all    = @(ConvertFrom-PacConnectionList $listed)
    if (-not $all.Count) {
        $listed | ForEach-Object { Write-Host "  $_" }
        throw "No connections were listed. Check 'pac auth list' points at $EnvironmentUrl."
    }

    $forConnector = @($all | Where-Object { $_.Connector -eq $Connector })
    $hit = @($forConnector | Where-Object { $_.Name -eq $Value -and $_.Status -eq 'Connected' })

    if ($hit.Count -eq 1) {
        Write-Log "Resolved '$Value' -> $($hit[0].Id)"
        return $hit[0].Id
    }

    $available = ($forConnector | ForEach-Object { "    $($_.Id)  $($_.Name)  [$($_.Status)]" }) -join "`n"
    if ($hit.Count -gt 1) {
        throw "'$Value' matches $($hit.Count) connected '$Connector' connections. Pass the id instead:`n$available"
    }
    throw "No connected '$Connector' connection named '$Value' in $EnvironmentUrl.`nAvailable:`n$(if ($available) { $available } else { '    (none)' })"
}

if ($UseConnection) {
    $pins['shared_commondataserviceforapps'] =
        Resolve-ConnectionName -Value $UseConnection -Connector 'shared_commondataserviceforapps' `
                               -Pac $pac -EnvironmentUrl $EnvironmentUrl
}


if ($DataverseOnly -and $SolutionZip) {
    $SolutionZip = Ensure-DataverseConnectionReferenceInSolution -SolutionZip (Resolve-Path -LiteralPath $SolutionZip).Path -EnvironmentUrl $EnvironmentUrl -DataRelativePath $DataFilePath
}

Write-Section 'READING THE SOLUTION'

$src = if ($SolutionZip) { '--solution-zip' } else { '--solution-folder' }
$val = if ($SolutionZip) { $SolutionZip }     else { $SolutionFolder }
if (-not (Test-Path -LiteralPath $val)) { throw "Not found: $val" }
$val = (Resolve-Path -LiteralPath $val).Path

# pac.cmd returns 0 even where it printed an error, so prove the file instead.
if (Test-Path -LiteralPath $SettingsFile) { Remove-Item -LiteralPath $SettingsFile -Force }
# Through Invoke-Pac, so an Error: line from pac throws here with pac's own
# message. Called directly, pac's exit code of 0 hides the cause and the only
# symptom is the missing file below - which says nothing about why.
Invoke-Pac @('solution', 'create-settings', $src, $val, '--settings-file', $SettingsFile)
if (-not (Test-Path -LiteralPath $SettingsFile)) {
    throw "pac solution create-settings reported success but $SettingsFile is not there."
}

$settings = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
$refs = @($settings.ConnectionReferences)
if (-not $refs) {
    if ($DataverseOnly) {
        Write-Log 'The solution declares no connection references. Nothing to bind, but continuing with Dataverse-only import.'
        $refs = @()
    } else {
        throw 'The solution declares no connection references - nothing to bind.'
    }
}
Write-Log "$($refs.Count) connection reference(s) in the solution."

# create-settings writes "Value": "" for every environment variable, and then the
# import rejects its own file with "Environment variable value can't be an empty
# string". An entry that is simply absent is fine - the value already baked into
# the solution is used - so drop the blanks rather than inventing values.
$vars  = @($settings.EnvironmentVariables)
$empty = @($vars | Where-Object { -not $_.Value })
if ($empty) {
    $settings.EnvironmentVariables = @($vars | Where-Object { $_.Value })
    Write-Log ("Dropped $($empty.Count) environment variable(s) with no value, keeping the solution's own: " +
               ($empty.SchemaName -join ', '))
}


if ($CreateDataverse -or ($CreateSharePoint -and -not $DataverseOnly)) {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is needed to create a connection.' }
    if (-not (az account show 2>$null)) { throw 'No Azure CLI session. Run: az login' }

    $paToken = az account get-access-token --resource 'https://service.powerapps.com/' --query accessToken -o tsv
    if (-not $paToken) { throw 'Could not get a Power Apps token.' }
    $paHeaders = @{ Authorization = "Bearer $paToken"; Accept = 'application/json' }

    if (-not $EnvironmentId) {
        # instanceApiUrl is https://org65efd8ed.api.crm.dynamics.com while callers
        # pass https://org65efd8ed.crm.dynamics.com, so match on the org name only.
        $org = ([uri]$EnvironmentUrl).Host -replace '\..*$', ''
        $all = (Invoke-RestMethod -Headers $paHeaders `
                    -Uri 'https://api.powerapps.com/providers/Microsoft.PowerApps/environments?api-version=2016-11-01').value
        $hit = @($all | Where-Object {
            $_.properties.linkedEnvironmentMetadata.instanceApiUrl -and
            (([uri]$_.properties.linkedEnvironmentMetadata.instanceApiUrl).Host -replace '\..*$', '') -eq $org })
        if ($hit.Count -ne 1) { throw "Could not resolve $EnvironmentUrl to one environment id ($($hit.Count) matched). Pass -EnvironmentId." }
        $EnvironmentId = $hit[0].name
    }
    Write-Log "Environment $EnvironmentId"

    # Every connection call wants this filter; without it the API answers
    # MissingEnvironmentFilter.
    $envFilter = '&%24filter=' + [uri]::EscapeDataString("environment eq '$EnvironmentId'")
}


if ($CreateDataverse) {
    Write-Section 'CREATING A DATAVERSE CONNECTION'

    if (-not $AppId)    { throw '-CreateDataverse needs -AppId.' }
    if (-not $TenantId) { throw '-CreateDataverse needs -TenantId.' }
    $secret = $env:PP_CLIENT_SECRET
    if (-not $secret) {
        throw 'Put the client secret in $env:PP_CLIENT_SECRET. It is deliberately not a parameter - a secret on a command line ends up in shell history and in every process listing.'
    }

    <#
      Created with `pac connection create`, not a hand-rolled PUT.

      The PUT this used to make went to the legacy route,

          https://api.powerapps.com/providers/Microsoft.PowerApps/apis/
              shared_commondataserviceforapps/connections/<id>?api-version=2016-11-01

      with a body whose connectionParametersSet is byte-for-byte what the portal
      sends. The resulting connection reports Connected, reads back identical to
      a portal-made one over GET - and then every call through the connector
      gateway comes back 403, which surfaces as an agent tool whose Row Item
      input will not expand.

      A HAR of make.powerapps.com creating the same kind of connection shows it
      does NOT use that route. It PUTs to

          https://<env>.environment.api.powerplatform.com/connectivity/
              connectors/shared_commondataserviceforapps/connections/<id>?api-version=1

      which needs an https://api.powerplatform.com/ token carrying delegated
      scopes the Azure CLI does not have - so calling it directly would mean a
      new app registration and admin consent.

      pac is already authenticated and does whatever Microsoft considers current,
      so it is both the smaller change and the more durable one.

      The cost: --client-secret is an argument, so it is visible in the process
      list for the life of the call. az login --service-principal has the same
      shape. The value still never goes on YOUR command line or into shell
      history - it comes from $env:PP_CLIENT_SECRET.
    #>
    Write-Log "Creating '$NewConnectionName' via pac connection create, as app $AppId (secret not logged)"
    Invoke-Pac @('connection', 'create',
                 '--environment',    $EnvironmentUrl,
                 '--name',           $NewConnectionName,
                 '--tenant-id',      $TenantId,
                 '--application-id', $AppId,
                 '--client-secret',  $secret)
    $secret = $null

    # pac does not print the id in a form worth parsing, so resolve the name it
    # was just given. An older connection with the same name would be ambiguous,
    # and Resolve-ConnectionName says so rather than guessing.
    $newId = Resolve-ConnectionName -Value $NewConnectionName -Connector 'shared_commondataserviceforapps' `
                                    -Pac $pac -EnvironmentUrl $EnvironmentUrl
    $url = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/' +
           "shared_commondataserviceforapps/connections/${newId}?api-version=2016-11-01" + $envFilter

    # A bad secret can still leave a connection behind, with the failure only in
    # statuses, so read back rather than trusting the create.
    $made   = Invoke-RestMethod -Uri $url -Headers $paHeaders
    $status = $made.properties.statuses | Select-Object -First 1
    if ($status.status -ne 'Connected') {
        throw "Connection $newId was created but is '$($status.status)': $($status.error.message). Check the secret, and that $AppId is an application user in this environment."
    }
    Write-Log "Created $newId  ($NewConnectionName)  Connected"

    # Pin it, so the binding below uses this one and not some older connection.
    $pins['shared_commondataserviceforapps'] = $newId
}


if ($CreateSharePoint -and -not $DataverseOnly) {
    Write-Section 'CREATING A SHAREPOINT CONNECTION'

    # SharePoint has no service principal option, so the connection has to be
    # consented to by a person. What can be automated is everything around that:
    # the shell, the consent link, catching the code the browser is handed back,
    # and the confirm. The human part is one sign-in, usually one click.
    $newSpId = 'shared-sharepointonl-' + [Guid]::NewGuid().ToString()
    $spUrl   = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/' +
               "shared_sharepointonline/connections/${newSpId}?api-version=2016-11-01" + $envFilter

    $spBody = @{ properties = @{
        displayName          = $SharePointConnectionName
        environment          = @{ id = "/providers/Microsoft.PowerApps/environments/$EnvironmentId"; name = $EnvironmentId }
        connectionParameters = @{}
    } } | ConvertTo-Json -Depth 10

    Invoke-RestMethod -Method Put -Uri $spUrl -Headers $paHeaders -ContentType 'application/json' -Body $spBody | Out-Null
    Write-Log "Created $newSpId unauthenticated, asking for a consent link"

    # Signing in at the consent link is what authenticates the connection; the
    # portal's follow-up confirmConsentCode call is bookkeeping, not a
    # requirement. Verified: a connection reaches Connected on sign-in alone.
    # So there is nothing to catch - ask the service, and poll.
    $redirect = 'https://make.powerapps.com/connection/oauth/redirect?oauthPopupId=' + [Guid]::NewGuid()
    $linkUrl  = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/' +
                "shared_sharepointonline/connections/$newSpId/getConsentLink?api-version=2016-11-01" + $envFilter
    $link = (Invoke-RestMethod -Method Post -Uri $linkUrl -Headers $paHeaders -ContentType 'application/json' `
                -Body (@{ redirectUrl = $redirect } | ConvertTo-Json)).consentLink
    if (-not $link) { throw 'The consent service returned no link.' }

    Write-Host ''
    Write-Host '  A browser window is opening. Sign in as the account the flows should run as.' -ForegroundColor Yellow
    Write-Host "  If it does not open, paste this in yourself:`n  $link"
    Start-Process $link

    $deadline = (Get-Date).AddSeconds($ConsentTimeoutSeconds)
    do {
        Start-Sleep -Seconds 3
        $spStatus = (Invoke-RestMethod -Uri $spUrl -Headers $paHeaders).properties.statuses | Select-Object -First 1
        Write-Host "  waiting for sign-in... $($spStatus.status)"
    } while ($spStatus.status -ne 'Connected' -and (Get-Date) -lt $deadline)

    if ($spStatus.status -ne 'Connected') {
        throw ("Still '$($spStatus.status)' after $ConsentTimeoutSeconds seconds. " +
               "Connection $newSpId is left behind - delete it in make.powerapps.com, or rerun with " +
               "-Connection shared_sharepointonline=$newSpId once you have signed it in there.")
    }

    $spMade = Invoke-RestMethod -Uri $spUrl -Headers $paHeaders
    Write-Log "Created $newSpId  ($($spMade.properties.displayName))  Connected as $($spMade.properties.authenticatedUser.name)"

    $pins['shared_sharepointonline'] = $newSpId
}


Write-Section "CONNECTIONS IN $EnvironmentUrl"

if ($DataverseOnly) {
    $conns = @()
    Write-Log 'Skipping pac connection list because Dataverse-only mode is enabled.'
} else {
    $listed = & $pac connection list --environment $EnvironmentUrl 2>&1 | ForEach-Object { "$_" }
    $conns  = @(ConvertFrom-PacConnectionList $listed)
    if (-not $conns) {
        $listed | ForEach-Object { Write-Host "  $_" }
        throw "No connections were listed. Check 'pac auth list' points at $EnvironmentUrl."
    }
    $conns | Group-Object Connector | ForEach-Object {
        Write-Log "$($_.Name): $($_.Count) connection(s)"
    }
}


Write-Section 'BINDING'

if ($DataverseOnly) {
    # Dropped from the file, not left blank. Skipping them in the loop and
    # leaving the entries behind is what made the unbound check below fire on
    # references -DataverseOnly was never going to bind. It also would not have
    # imported: pac rejects an empty ConnectionId the same way it rejects an
    # empty environment variable value, while an entry that is simply ABSENT
    # imports cleanly and leaves that reference unbound - which is the point.
    $isDv  = { ($_.ConnectorId -replace '^.*/', '') -eq 'shared_commondataserviceforapps' }
    $skip  = @($refs | Where-Object { -not (& $isDv) })
    if ($skip.Count) {
        $refs = @($refs | Where-Object $isDv)
        $settings.ConnectionReferences = $refs
        Write-Log ("Dropped $($skip.Count) non-Dataverse reference(s) from the settings file; the import leaves them unbound: " +
                   (@($skip | ForEach-Object { $_.LogicalName }) -join ', '))
    }
    if (-not $refs.Count) { throw 'No Dataverse connection reference to bind - nothing for -DataverseOnly to do.' }
}

foreach ($r in $refs) {
    $connector = $r.ConnectorId -replace '^.*/', ''

    if ($pins.ContainsKey($connector)) {
        $r.ConnectionId = $pins[$connector]
        Write-Log "$connector -> $($r.ConnectionId)  (-Connection)"
        continue
    }

    $candidates = @($conns | Where-Object { $_.Connector -eq $connector -and $_.Status -eq 'Connected' })

    if ($candidates.Count -eq 0) {
        throw @"
No connected '$connector' connection exists in $EnvironmentUrl.

Create one first - these connectors sign in as a user, so the first one needs a
human to consent:

    Dataverse    pac connection create -env $EnvironmentUrl -n "<name>" -t <tenant> -a <appid> -cs <secret>
    SharePoint   $EnvironmentUrl -> make.powerapps.com -> Connections -> New connection

then run this again.
"@
    }

    if ($candidates.Count -eq 1) {
        $r.ConnectionId = $candidates[0].Id
        Write-Log "$connector -> $($r.ConnectionId)"
        continue
    }

    # Several match. Guessing here binds the agent to whichever connection the
    # API happened to return first, which is how a tool ends up reading the
    # wrong site, so ask instead.
    Write-Host "`n  $($refs.IndexOf($r) + 1). $($r.LogicalName)"
    Write-Host "  $($candidates.Count) '$connector' connections match:"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("    [{0}] {1}  {2}" -f ($i + 1), $candidates[$i].Id, $candidates[$i].Name)
    }
    $answer = (Read-Host "  Pick 1-$($candidates.Count)").Trim()
    $pick = 0
    if (-not [int]::TryParse($answer, [ref]$pick) -or $pick -lt 1 -or $pick -gt $candidates.Count) {
        throw "'$answer' is not one of 1-$($candidates.Count). Pass -Connection $connector=<id> to run unattended."
    }
    $r.ConnectionId = $candidates[$pick - 1].Id
    Write-Log "$connector -> $($r.ConnectionId)"
}

$blank = @($refs | Where-Object { -not $_.ConnectionId })
if ($blank) { throw "Still unbound: $($blank.LogicalName -join ', ')" }

# UTF8 without a BOM: pac reads this file as JSON and a BOM has bitten this
# pipeline before.
[System.IO.File]::WriteAllText(
    $SettingsFile,
    ($settings | ConvertTo-Json -Depth 20),
    (New-Object System.Text.UTF8Encoding $false))

Write-Log "Wrote $SettingsFile"


if ($Import) {
    Write-Section "IMPORT INTO $EnvironmentUrl"
    $out = & $pac solution import --environment $EnvironmentUrl --path $SolutionZip `
                --settings-file $SettingsFile --publish-changes --force-overwrite `
                --activate-plugins --max-async-wait-time 60 2>&1 | ForEach-Object { "$_" }
    $out | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0 -or ($out -match '^\s*Error:')) {
        # Carry pac's own lines into the exception. Without them the throw is all
        # the caller sees once the console has scrolled.
        $why = @($out | Where-Object { $_ -match '(?i)error|fail|unable|cannot|missing' }) -join "`n  "
        throw ("Import failed.`n  " + $why +
               "`n`nThe settings file is at $SettingsFile - it is reusable, fix the cause and rerun with -Import.")
    }

    <#
      Prove the binding rather than trusting the import.

      "Import succeeded" says the solution landed, not that each connection
      reference came out pointing at a connection. A reference that imports
      unbound looks identical from here and only shows up later as a tool that
      cannot call anything - so read the rows back and compare.
    #>
    Write-Section 'RE-ASSERTING AND VERIFYING THE BINDING'

    <#
      Two jobs, and the first is not as redundant as it looks.

      A HAR of make.powerapps.com captured while switching a connection - the
      action that makes an agent tool's Inputs panel render instead of coming up
      empty - shows the whole thing is a single write:

          PATCH /api/data/v9.0/connectionreferences(<id>)
          { "connectionreferenceid": "<id>", "connectionid": "<connection>" }

      Nothing else; the rest of that capture is telemetry and solution summaries.
      So this repeats that exact call for every reference after the import. One
      request each, and it reproduces the only action anyone has found that
      reliably clears the blank panel.

      Whether it helps when the import already wrote the same value is NOT
      established - it may be a server-side no-op. It is here because it is the
      one step with direct evidence behind it, and re-asserting a value the
      import was supposed to set cannot make things worse.

      Then read the rows back: "import succeeded" says the solution landed, not
      that each reference came out pointing at a connection.
    #>
    $dvToken = az account get-access-token --resource $EnvironmentUrl --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $dvToken) {
        Write-Log "Could not get a Dataverse token - skipping re-assert and verify. ($dvToken)"
    }
    else {
        $dvHeaders = @{
            Authorization   = "Bearer $("$dvToken".Trim())"
            Accept          = 'application/json'
            'If-Match'      = '*'          # update only, never upsert a new row
            'OData-Version' = '4.0'
        }
        $sel  = '$select=connectionreferenceid,connectionreferencelogicalname,connectionid'
        $live = @((Invoke-RestMethod -Uri "$EnvironmentUrl/api/data/v9.2/connectionreferences?$sel" -Headers $dvHeaders).value)

        $bad = @()
        foreach ($r in $refs) {
            $row = $live | Where-Object { $_.connectionreferencelogicalname -eq $r.LogicalName } | Select-Object -First 1
            if (-not $row) { $bad += "$($r.LogicalName) - no such reference in the environment"; continue }

            $uri = "$EnvironmentUrl/api/data/v9.2/connectionreferences($($row.connectionreferenceid))"
            try {
                $body = @{
                    connectionreferenceid = $row.connectionreferenceid
                    connectionid          = $r.ConnectionId
                } | ConvertTo-Json
                Invoke-RestMethod -Method Patch -Uri $uri -Headers $dvHeaders `
                                  -ContentType 'application/json' -Body $body | Out-Null
                Write-Log "  re-asserted: $($r.LogicalName)"
            }
            catch {
                $bad += "$($r.LogicalName) - could not set connectionid: $($_.Exception.Message)"
                continue
            }

            $after = Invoke-RestMethod -Uri "$uri`?`$select=connectionid" -Headers $dvHeaders
            if ($after.connectionid -ne $r.ConnectionId) {
                $bad += "$($r.LogicalName) - reads back as '$($after.connectionid)', expected '$($r.ConnectionId)'"
            }
            else {
                Write-Log "  verified:    $($r.LogicalName) -> $($after.connectionid)"
            }
        }

        if ($bad.Count) {
            throw ("The import reported success but the bindings are not right:`n  " + ($bad -join "`n  ") +
                   "`n`nThe settings file is at $SettingsFile.")
        }
        Write-Log "All $($refs.Count) reference(s) bound and verified."
    }
}


Write-Section 'DONE'
$refs | Select-Object @{n = 'Connector'; e = { $_.ConnectorId -replace '^.*/', '' } }, ConnectionId, LogicalName |
    Format-Table -AutoSize
if (-not $Import) { Write-Host "Import with:  pac solution import --environment $EnvironmentUrl --path <zip> --settings-file $SettingsFile" }
