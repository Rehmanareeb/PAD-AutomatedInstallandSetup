$ErrorActionPreference = 'Stop'
$dir  = $PSScriptRoot
$fail = 0

function New-Settings {
    [pscustomobject]@{
        ConnectionReferences = @(
            [pscustomobject]@{ LogicalName = 'cr720_dv';  ConnectorId = '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps'; ConnectionId = '' }
            [pscustomobject]@{ LogicalName = 'cr720_sp';  ConnectorId = '/providers/Microsoft.PowerApps/apis/shared_sharepointonline';         ConnectionId = '' }
            [pscustomobject]@{ LogicalName = 'cr720_cua'; ConnectorId = '/providers/Microsoft.PowerApps/apis/shared_computeroperator';         ConnectionId = '' }
        )
        EnvironmentVariables = @()
    }
}

function Check { param([string] $Name, [bool] $Ok, [string] $Got)
    if (-not $Ok) { $script:fail++ }
    '{0} {1,-46} {2}' -f $(if ($Ok) { 'OK  ' } else { 'FAIL' }), $Name, $Got
}

foreach ($file in 'Prepare-Sol.ps1', 'Run-HandOver.ps1') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$dir\$file", [ref]$null, [ref]$null)
    $fn  = ($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                           $args[0].Name -eq 'Split-DeferredReferences' }, $true))[0]
    if (-not $fn) { Write-Host "FAIL $file - Split-DeferredReferences not found" -ForegroundColor Red; $fail++; continue }
    . ([scriptblock]::Create($fn.Extent.Text))

    $s = New-Settings
    $r = Split-DeferredReferences -SettingsObject $s -DeferConnector @('shared_computeroperator')
    Check "$file the CUA ref is deferred"        (@($r.Deferred).Count -eq 1 -and $r.Deferred[0].LogicalName -eq 'cr720_cua') (@($r.Deferred | ForEach-Object { $_.LogicalName }) -join ',')
    Check "$file the other two still bind"       (@($r.Bind).Count -eq 2) (@($r.Bind | ForEach-Object { $_.LogicalName }) -join ',')
    Check "$file it is dropped from the file"    (@($s.ConnectionReferences).Count -eq 2 -and @($s.ConnectionReferences | Where-Object { $_.LogicalName -eq 'cr720_cua' }).Count -eq 0) (@($s.ConnectionReferences | ForEach-Object { $_.LogicalName }) -join ',')
    Check "$file dropped, not blanked"           (($s | ConvertTo-Json -Depth 10) -notmatch 'computeroperator') 'no computeroperator entry in the JSON'

    $s2 = New-Settings
    $r2 = Split-DeferredReferences -SettingsObject $s2 -DeferConnector @()
    Check "$file nothing deferred leaves all 3"  (@($r2.Bind).Count -eq 3 -and @($r2.Deferred).Count -eq 0 -and @($s2.ConnectionReferences).Count -eq 3) (@($r2.Bind | ForEach-Object { $_.LogicalName }) -join ',')

    $s3 = New-Settings
    $r3 = Split-DeferredReferences -SettingsObject $s3 -DeferConnector @('shared_commondataserviceforapps', 'shared_computeroperator')
    Check "$file two deferred at once"           (@($r3.Bind).Count -eq 1 -and $r3.Bind[0].LogicalName -eq 'cr720_sp') (@($r3.Bind | ForEach-Object { $_.LogicalName }) -join ',')

    $s4 = [pscustomobject]@{ ConnectionReferences = @(); EnvironmentVariables = @() }
    $r4 = Split-DeferredReferences -SettingsObject $s4 -DeferConnector @('shared_computeroperator')
    Check "$file no references at all"           (@($r4.Bind).Count -eq 0 -and @($r4.Deferred).Count -eq 0) 'empty in, empty out'
}

function Get-ParamDefault { param([string] $File, [string] $Param)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$dir\$File", [ref]$null, [ref]$null)
    $p = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] -and
                        $args[0].Name.VariablePath.UserPath -eq $Param }, $true)
    @($p | ForEach-Object { $_.DefaultValue.Extent.Text }) -join ' | '
}

foreach ($file in 'Prepare-Sol.ps1', 'Run-HandOver.ps1') {
    $defer   = Get-ParamDefault $file 'DeferConnector'
    $consent = Get-ParamDefault $file 'ConsentConnector'

    Check "$file defers shared_computeroperator"   ($defer   -match 'shared_computeroperator')      $defer
    Check "$file consents microsoftcopilotstudio"  ($consent -match 'shared_microsoftcopilotstudio') $consent
    Check "$file does NOT auto-consent SharePoint" ($consent -notmatch 'shared_sharepointonline')    $consent
    Check "$file does NOT consent computeroperator" ($consent -notmatch 'shared_computeroperator')   $consent

    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$dir\$file", [ref]$null, [ref]$null)
    $defs  = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                              $args[0].Name -eq 'New-ConsentedConnection' }, $true))
    $calls = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                              $args[0].GetCommandName() -eq 'New-ConsentedConnection' }, $true))
    Check "$file one consent helper, used twice" ($defs.Count -eq 1 -and $calls.Count -eq 2) "def=$($defs.Count) calls=$($calls.Count)"

    <#
      The 401: with -SkipCreateDataverse -SkipCreateSharePoint the token block
      was skipped, so the consent PUT went out with no Authorization header.
      The gate must name ConsentConnector, and the helper must refuse to PUT
      without headers rather than let the service answer 401.
    #>
    $gate = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and
                             $args[0].Clauses[0].Item1.Extent.Text -match 'DoDataverse\s+-or\s+\$DoSharePoint' }, $true))
    Check "$file token gate covers ConsentConnector" ($gate.Count -eq 1 -and $gate[0].Clauses[0].Item1.Extent.Text -match 'ConsentConnector') $(if ($gate.Count) { $gate[0].Clauses[0].Item1.Extent.Text } else { 'gate not found' })
    Check "$file helper refuses PUT with no headers" ($defs.Count -eq 1 -and $defs[0].Extent.Text -match '-not \$paHeaders') 'guard present'
    Check "$file helper defined before first use" ($defs.Count -eq 1 -and $calls.Count -and $defs[0].Extent.StartLineNumber -lt ($calls | ForEach-Object { $_.Extent.StartLineNumber } | Sort-Object)[0]) "def L$($defs[0].Extent.StartLineNumber)"
}

if ($fail) { Write-Host "`n$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nall passed - the Computer Use reference is dropped from the settings file, not blanked, and stage 2 binds it" -ForegroundColor Green
