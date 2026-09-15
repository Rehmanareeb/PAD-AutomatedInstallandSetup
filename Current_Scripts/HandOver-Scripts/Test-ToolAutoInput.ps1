$ErrorActionPreference = 'Stop'
$dir  = $PSScriptRoot
$fail = 0

function Check { param([string] $Name, [bool] $Ok, [string] $Got)
    if (-not $Ok) { $script:fail++ }
    '{0} {1,-50} {2}' -f $(if ($Ok) { 'OK  ' } else { 'FAIL' }), $Name, $Got
}

<#
  The real component file, trimmed to the shape that matters: a ManualTaskInput
  with a value, AutomaticTaskInputs without one, a blank line between entries,
  and a top-level key after the block.
#>
$sample = @'
kind: TaskDialog
inputs:
  - kind: ManualTaskInput
    propertyName: organization
    value: https://org65efd8ed.crm.dynamics.com

  - kind: ManualTaskInput
    propertyName: entityName
    value: cr720_uahtestscripts

  - kind: AutomaticTaskInput
    propertyName: item.'cr720_csvcontent'

  - kind: AutomaticTaskInput
    propertyName: item.'cr720_usecase'

modelDisplayName: Add a new row to selected environment
outputs:
  - propertyName: cr720_csvfilename
    name: CSV File Name
'@

$want = @('cr720_csvfilename', 'cr720_csvsharepointurl')

foreach ($file in 'Prepare-Sol.ps1', 'Run-HandOver.ps1') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$dir\$file", [ref]$null, [ref]$null)
    $fn  = ($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                           $args[0].Name -eq 'Add-ToolAutoInput' }, $true))[0]
    if (-not $fn) { Write-Host "FAIL $file - Add-ToolAutoInput not found" -ForegroundColor Red; $fail++; continue }
    . ([scriptblock]::Create($fn.Extent.Text))

    $p = Join-Path ([IO.Path]::GetTempPath()) ("tool_" + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($p, $sample)

        $added = @(Add-ToolAutoInput -File $p -Properties $want)
        Check "$file adds both missing columns" ((($added -join ',') -eq ($want -join ','))) ($added -join ',')

        $after = [IO.File]::ReadAllLines($p)
        $inputStart = [Array]::FindIndex($after, [Predicate[string]]{ param($l) $l -eq 'inputs:' })
        $blockEnd   = [Array]::FindIndex($after, [Predicate[string]]{ param($l) $l -match '^modelDisplayName:' })

        foreach ($c in $want) {
            $idx = [Array]::FindIndex($after, [Predicate[string]]{ param($l) $l.Trim() -eq "propertyName: item.'$c'" }.GetNewClosure())
            Check "$file $c landed inside inputs:" ($idx -gt $inputStart -and $idx -lt $blockEnd) "line $($idx + 1), block is $($inputStart + 1)..$blockEnd"
            Check "$file $c is an AutomaticTaskInput" ($after[$idx - 1].Trim() -eq '- kind: AutomaticTaskInput') $after[$idx - 1].Trim()
            Check "$file $c carries no value" (($idx + 1 -ge $after.Count) -or ($after[$idx + 1] -notmatch '^\s*value:')) 'no value: line follows'
        }

        # the existing content must survive untouched
        Check "$file organization value untouched" (($after | Where-Object { $_ -match 'org65efd8ed' }).Count -eq 1) 'still there'
        Check "$file existing auto inputs kept"    (($after | Where-Object { $_ -match "item\.'cr720_(csvcontent|usecase)'" }).Count -eq 2) 'both kept'
        Check "$file outputs section untouched"    (($after | Where-Object { $_ -match '^outputs:' }).Count -eq 1) 'outputs: intact'

        # second run must change nothing
        $before2 = [IO.File]::ReadAllText($p)
        $again   = @(Add-ToolAutoInput -File $p -Properties $want)
        Check "$file second run adds nothing"  ($again.Count -eq 0) "added $($again.Count)"
        Check "$file second run leaves file identical" ([IO.File]::ReadAllText($p) -eq $before2) 'byte-identical'

        # empty list is a no-op
        $none = @(Add-ToolAutoInput -File $p -Properties @())
        Check "$file empty -Properties is a no-op" ($none.Count -eq 0 -and [IO.File]::ReadAllText($p) -eq $before2) 'unchanged'
    }
    finally { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
}

foreach ($file in 'Prepare-Sol.ps1', 'Run-HandOver.ps1') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$dir\$file", [ref]$null, [ref]$null)
    $p = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] -and
                        $args[0].Name.VariablePath.UserPath -eq 'DataverseToolAutoInput' }, $true)
    $def = @($p | ForEach-Object { $_.DefaultValue.Extent.Text }) -join ''
    Check "$file default names both columns" (($def -match 'cr720_csvfilename') -and ($def -match 'cr720_csvsharepointurl')) $def

    $calls = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                              $args[0].GetCommandName() -eq 'Add-ToolAutoInput' }, $true))
    Check "$file wired into the retarget step" ($calls.Count -eq 1) "calls=$($calls.Count)"
}

if ($fail) { Write-Host "`n$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nall passed - both columns are added as AI-filled inputs, inside the block, without disturbing anything else" -ForegroundColor Green
