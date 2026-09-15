$ErrorActionPreference = 'Stop'
$dir  = $PSScriptRoot
$fail = 0

function Check { param([string] $Name, [bool] $Ok, [string] $Got)
    if (-not $Ok) { $script:fail++ }
    '{0} {1,-52} {2}' -f $(if ($Ok) { 'OK  ' } else { 'FAIL' }), $Name, $Got
}

<#
  This solution puts TWO references on the same connector: one on the agent
  tool, one used by the four cloud flows. -Connection can only speak to the
  connector, so -ConnectionRef exists to address a single reference.

  Both are fine on the service principal connection - that was measured in the
  designer, with dataverse-sp bound and every input present.
#>
$TOOL = "cr720_Agent1TestScript.shared_commondataserviceforapps.shared-commondataser-b3156325-9848-4bd2-bb48-1d2a3e362750"
$FLOW = "copilots_header_7fa8c.shared_commondataserviceforapps.shared-commondataser-23ad1384-e047-4015-bbd7-428c1e892330"
$DV   = 'shared_commondataserviceforapps'
$SPID = 'sp0000000000000000000000000000000'
$ME   = 'me1111111111111111111111111111111'

foreach ($file in 'Prepare-Sol.ps1', 'Run-HandOver.ps1') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$dir\$file", [ref]$null, [ref]$null)
    $fn  = ($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                           $args[0].Name -eq 'Select-ReferenceConnection' }, $true))[0]
    if (-not $fn) { Write-Host "FAIL $file - Select-ReferenceConnection not found" -ForegroundColor Red; $fail++; continue }
    . ([scriptblock]::Create($fn.Extent.Text))

    $one = @([pscustomobject]@{ Id = $SPID; Name = 'dataverse-sp' })
    $two = @([pscustomobject]@{ Id = $SPID; Name = 'dataverse-sp' }, [pscustomobject]@{ Id = $ME; Name = 'mine' })

    $r = Select-ReferenceConnection -LogicalName $TOOL -Connector $DV -RefPins @{} -Pins @{ $DV = $SPID } -Candidates $two
    Check "$file connector pin binds the agent tool"  ($r.Id -eq $SPID) "$($r.Id) - $($r.Why)"

    $r = Select-ReferenceConnection -LogicalName $FLOW -Connector $DV -RefPins @{} -Pins @{ $DV = $SPID } -Candidates $two
    Check "$file connector pin binds the flow ref"    ($r.Id -eq $SPID) "$($r.Id) - $($r.Why)"

    $r = Select-ReferenceConnection -LogicalName $TOOL -Connector $DV -RefPins @{ $TOOL = $ME } -Pins @{ $DV = $SPID } -Candidates $two
    Check "$file -ConnectionRef beats -Connection"    ($r.Id -eq $ME) "$($r.Id) - $($r.Why)"

    $r = Select-ReferenceConnection -LogicalName $FLOW -Connector $DV -RefPins @{ $TOOL = $ME } -Pins @{ $DV = $SPID } -Candidates $two
    Check "$file a ref pin touches only that ref"     ($r.Id -eq $SPID) "$($r.Id) - $($r.Why)"

    $r = Select-ReferenceConnection -LogicalName $TOOL -Connector $DV -RefPins @{} -Pins @{} -Candidates $one
    Check "$file one candidate binds silently"        ($r.Id -eq $SPID) "$($r.Id) - $($r.Why)"

    $r = Select-ReferenceConnection -LogicalName $TOOL -Connector $DV -RefPins @{} -Pins @{} -Candidates $two
    Check "$file two candidates ask instead of guess" ($null -eq $r.Id -and @($r.Choices).Count -eq 2) 'prompts'

    $r = Select-ReferenceConnection -LogicalName $TOOL -Connector $DV -RefPins @{} -Pins @{} -Candidates @()
    Check "$file none falls through to the caller"    ($null -eq $r.Id -and $null -eq $r.Choices) 'empty, caller decides'
}

foreach ($file in 'Prepare-Sol.ps1', 'Run-HandOver.ps1') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$dir\$file", [ref]$null, [ref]$null)
    $p = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] -and
                        $args[0].Name.VariablePath.UserPath -eq 'ConnectionRef' }, $true)
    Check "$file exposes -ConnectionRef" (@($p).Count -eq 1) "found $(@($p).Count)"

    $src = Get-Content "$dir\$file" -Raw
    Check "$file no service-principal special case" ($src -notmatch 'ServicePrincipalId|BotOwned') 'reverted cleanly'
}

if ($fail) { Write-Host "`n$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nall passed - references bind by pin then by connector, and -ConnectionRef can single one out" -ForegroundColor Green
