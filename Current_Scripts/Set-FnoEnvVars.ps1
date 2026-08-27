<#
.SYNOPSIS
  Point the Fno username/password environment variable definitions of an unpacked
  solution at the given Key Vault secrets. Publisher prefix is matched dynamically.
  -SolutionPath is required and must be the unpacked solution root (the folder holding Other\Solution.xml).
.EXAMPLE
  .\Set-FnoEnvVars.ps1 -SolutionPath .\CUAExecutionValidator_extracted
  .\Set-FnoEnvVars.ps1 -SolutionPath .\MySolution -UsernameValue '/subscriptions/.../secrets/Other-User'
#>
[CmdletBinding()]
param(
    [string]$SolutionPath,

    [string]$UsernameValue,
    [string]$PasswordValue,

    [string]$PackTo,
    [switch]$NoPack,

    [switch]$SelfTest
)

# Dataverse rejects a secret-type value that does not match this. Anchored so trailing junk fails here
# instead of at import time with "This variable didn't save properly."
$SecretRefPattern = '(?i)^/subscriptions/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/resourcegroups/(.+?)/providers/Microsoft\.KeyVault/(.+?)/secrets/(.+)$'
$SecretRefHint = 'Valid format: /subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>/secrets/<secret>'

$DefaultUsernameValue = '/subscriptions/0c33fa37-4fa1-466d-a891-46af9e2f6e44/resourceGroups/DemoResourceGroup/providers/Microsoft.KeyVault/vaults/CUA-vault-key/secrets/Fno-Usernames'
$DefaultPasswordValue = '/subscriptions/0c33fa37-4fa1-466d-a891-46af9e2f6e44/resourceGroups/DemoResourceGroup/providers/Microsoft.KeyVault/vaults/CUA-vault-key/secrets/fno-password'

function New-KeyVaultSecretPath {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$VaultName, [string]$SecretName)
    "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$VaultName/secrets/$SecretName"
}

function Read-Required {
    param([string]$Prompt)
    do { $answer = (Read-Host $Prompt).Trim() } while (-not $answer)
    $answer
}

function Set-FnoEnvVar {
    param([string]$Path, [string]$UsernameValue, [string]$PasswordValue)

    $xml = New-Object System.Xml.XmlDocument
    $xml.Load((Resolve-Path $Path))
    $def = $xml.DocumentElement
    $schema = $def.GetAttribute('schemaname')

    $value = switch -Regex ($schema) {
        '_FnoUsername$' { $UsernameValue; break }
        '_FnoPassword$' { $PasswordValue; break }
        default { return $null }
    }

    $node = $def.SelectSingleNode('defaultvalue')
    if (-not $node) {
        $node = $xml.CreateElement('defaultvalue')
        [void]$def.InsertBefore($node, $def.FirstChild)
    }
    $old = $node.InnerText
    $node.InnerText = $value
    $xml.Save((Resolve-Path $Path))

    [pscustomobject]@{ SchemaName = $schema; File = $Path; OldValue = $old; NewValue = $value }
}

if ($SelfTest) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("fnotest_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        # has a defaultvalue -> replaced; different publisher prefix -> still matched
        $a = Join-Path $tmp 'a.xml'
        Set-Content $a '<environmentvariabledefinition schemaname="abc12_FnoUsername"><defaultvalue>stale</defaultvalue><type>100000005</type></environmentvariabledefinition>'
        # no defaultvalue -> inserted
        $b = Join-Path $tmp 'b.xml'
        Set-Content $b '<environmentvariabledefinition schemaname="abc12_FnoPassword"><type>100000005</type></environmentvariabledefinition>'
        # unrelated variable -> untouched
        $c = Join-Path $tmp 'c.xml'
        Set-Content $c '<environmentvariabledefinition schemaname="abc12_ApiUrl"><defaultvalue>keepme</defaultvalue></environmentvariabledefinition>'

        $ra = Set-FnoEnvVar -Path $a -UsernameValue 'U' -PasswordValue 'P'
        $rb = Set-FnoEnvVar -Path $b -UsernameValue 'U' -PasswordValue 'P'
        $rc = Set-FnoEnvVar -Path $c -UsernameValue 'U' -PasswordValue 'P'

        if ($ra.OldValue -ne 'stale') { throw 'existing value not read' }
        if (([xml](Get-Content $a)).environmentvariabledefinition.defaultvalue -ne 'U') { throw 'username not replaced' }
        if (([xml](Get-Content $b)).environmentvariabledefinition.defaultvalue -ne 'P') { throw 'password not inserted' }
        if (([xml](Get-Content $c)).environmentvariabledefinition.defaultvalue -ne 'keepme') { throw 'unrelated var touched' }
        if ($null -ne $rc) { throw 'unrelated var reported as changed' }

        $built = New-KeyVaultSecretPath -SubscriptionId 'sub' -ResourceGroup 'rg' -VaultName 'kv' -SecretName 'sec'
        if ($built -ne '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv/secrets/sec') { throw 'bad secret path' }

        if ($DefaultUsernameValue -notmatch $SecretRefPattern) { throw 'default username value fails the secret-reference format' }
        if ($DefaultPasswordValue -notmatch $SecretRefPattern) { throw 'default password value fails the secret-reference format' }
        $good = New-KeyVaultSecretPath '0c33fa37-4fa1-466d-a891-46af9e2f6e44' 'rg' 'kv' 'sec'
        if ($good -notmatch $SecretRefPattern) { throw 'built path rejected by pattern' }
        foreach ($bad in @(
                'not-a-path',
                '/subscriptions/nope/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv/secrets/sec',   # bad guid
                '/subscriptions/0c33fa37-4fa1-466d-a891-46af9e2f6e44/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv/sec', # no /secrets/
                "https://kv.vault.azure.net/secrets/sec")) {                                                   # vault URL, not a resource id
            if ($bad -match $SecretRefPattern) { throw "pattern wrongly accepted: '$bad'" }
        }
        'SelfTest OK'
    } finally { Remove-Item $tmp -Recurse -Force }
    return
}

if (-not $SolutionPath) { Write-Error 'Pass -SolutionPath <unpacked solution root>.'; return }
if (-not (Test-Path -Path $SolutionPath -PathType Container)) { Write-Error "Solution path '$SolutionPath' does not exist."; return }

$manifest = Join-Path $SolutionPath 'Other\Solution.xml'
if (-not (Test-Path $manifest)) { Write-Error "'$SolutionPath' is not an unpacked solution root - Other\Solution.xml is missing."; return }

# Create any missing Fno definition (folder + xml, no defaultvalue yet) before prompting.
foreach ($name in 'FnoUsername', 'FnoPassword') {
    $existing = Get-ChildItem -Path $SolutionPath -Recurse -Filter 'environmentvariabledefinition.xml' -File |
        Where-Object { ([xml](Get-Content $_.FullName -Raw)).environmentvariabledefinition.schemaname -match "_$name$" }
    if ($existing) { continue }

    if (-not $prefix) {
        $prefix = ([xml](Get-Content $manifest -Raw)).SelectSingleNode('//CustomizationPrefix').InnerText
        if (-not $prefix) { $prefix = Read-Required 'Publisher prefix (not found in Solution.xml)' }
    }

    $schema = "${prefix}_$name"
    $dir = Join-Path (Join-Path $SolutionPath 'environmentvariabledefinitions') $schema
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    @"
<environmentvariabledefinition schemaname="$schema">
  <displayname default="$name">
    <label description="$name" languagecode="1033" />
  </displayname>
  <introducedversion>1.0.0.0</introducedversion>
  <iscustomizable>1</iscustomizable>
  <isrequired>0</isrequired>
  <secretstore>0</secretstore>
  <type>100000005</type>
</environmentvariabledefinition>
"@ | Set-Content -Path (Join-Path $dir 'environmentvariabledefinition.xml') -Encoding utf8
    Write-Host "Created $schema"
}

$fromParams = $UsernameValue -and $PasswordValue

while ($true) {
    if (-not $UsernameValue -or -not $PasswordValue) {
        Write-Host ''
        Write-Host '  1) Default values (Demo subscription / CUA-vault-key)'
        Write-Host '  2) Dynamic values (enter your own)'
        do { $choice = (Read-Host 'Choice [1/2]').Trim() } while ($choice -notin '1', '2')

        if ($choice -eq '1') {
            $UsernameValue = $DefaultUsernameValue
            $PasswordValue = $DefaultPasswordValue
        }
        else {
            $sub   = Read-Required 'Subscription-id'
            $rg    = Read-Required 'Resource Group'
            $vault = Read-Required 'Vault Name'
            $UsernameValue = New-KeyVaultSecretPath $sub $rg $vault (Read-Required 'Secrets name (username)')
            $PasswordValue = New-KeyVaultSecretPath $sub $rg $vault (Read-Required 'Secrets name (password)')
        }
        Write-Host ''
    }

    $invalid = @(
        @{ Name = 'Username'; Value = $UsernameValue }
        @{ Name = 'Password'; Value = $PasswordValue }
    ) | Where-Object { $_.Value -notmatch $SecretRefPattern }
    if (-not $invalid) { break }

    $invalid | ForEach-Object { Write-Warning "$($_.Name) value is not a valid secret reference: $($_.Value)" }
    Write-Warning $SecretRefHint
    if ($fromParams) { Write-Error 'Nothing written - fix the value and run again.'; return }
    $UsernameValue = $PasswordValue = $null   # re-prompt
}

$files = Get-ChildItem -Path $SolutionPath -Recurse -Filter 'environmentvariabledefinition.xml' -File
if (-not $files) { Write-Warning "No environmentvariabledefinition.xml under '$SolutionPath' - is this an unpacked solution?"; return }

$changed = $files | ForEach-Object { Set-FnoEnvVar -Path $_.FullName -UsernameValue $UsernameValue -PasswordValue $PasswordValue }

if (-not $changed) { Write-Warning 'No Fno username/password environment variables found in this solution.'; return }
$changed | Format-Table SchemaName, OldValue, NewValue -AutoSize

if ($NoPack) { return }

if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Error 'pac CLI is missing and dotnet was not found - install the .NET SDK (or the Power Platform Tools VS Code extension), then re-run. Solution left unpacked.'
        return
    }
    Write-Host 'pac CLI not found - installing Microsoft.PowerApps.CLI.Tool ...'
    dotnet tool install --global Microsoft.PowerApps.CLI.Tool
    if ($LASTEXITCODE -ne 0) { dotnet tool update --global Microsoft.PowerApps.CLI.Tool }   # already installed, just not on PATH
    $env:PATH = "$env:PATH;$HOME\.dotnet\tools"
    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        Write-Error 'pac install did not put pac on PATH - open a new shell and re-run. Solution left unpacked.'
        return
    }
}

$root = (Resolve-Path $SolutionPath).Path.TrimEnd('\')
if (-not $PackTo) { $PackTo = "$root.zip" }
$packageType = if (([xml](Get-Content $manifest -Raw)).SelectSingleNode('//Managed').InnerText -eq '1') { 'Managed' } else { 'Unmanaged' }

Write-Host "Packing $packageType solution -> $PackTo"
pac solution pack --zipfile $PackTo --folder $root --packagetype $packageType
if ($LASTEXITCODE -ne 0) { Write-Error "pac solution pack failed (exit $LASTEXITCODE)." }
