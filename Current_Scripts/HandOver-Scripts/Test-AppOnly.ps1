$ErrorActionPreference = 'Stop'
$dir  = 'C:\Users\cindy\Desktop\cloned_Repos_inferifi\RnD\Current_Scripts\HandOver-Scripts'
$fail = 0

function Get-Fn { param($File, $Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$dir\$File", [ref]$null, [ref]$null)
    ($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $args[0].Name -eq $Name }, $true))[0]
}

foreach ($file in 'Prepare-Sol.ps1', 'Run-HandOver.ps1', 'Machine-and-Cua.ps1') {
    $wantCaller = $file -ne 'Machine-and-Cua.ps1'

    $assert = Get-Fn $file 'Assert-AzUserSession'
    if (-not $assert) { "FAIL $file - Assert-AzUserSession missing"; $fail++; continue }
    . ([scriptblock]::Create($assert.Extent.Text))

    if ($wantCaller) {
        $caller = Get-Fn $file 'Get-AzCallerIdentity'
        if (-not $caller) { "FAIL $file - Get-AzCallerIdentity missing"; $fail++; continue }
        . ([scriptblock]::Create($caller.Extent.Text))
    }

    foreach ($case in @(
        @{ Kind = 'user';             Blocks = $false; Type = 'User';             Oid = 'USER-OID' }
        @{ Kind = 'servicePrincipal'; Blocks = $true;  Type = 'ServicePrincipal'; Oid = 'SP-OID'   }
        @{ Kind = '';                 Blocks = $true;  Type = $null;              Oid = $null     }
    )) {
        $script:kind = $case.Kind
        function Get-AzSessionKind { $script:kind }
        function Invoke-Az {
            param([string[]] $Arguments, [string] $ErrorMessage, [switch] $AllowFailure)
            if ($Arguments -contains 'signed-in-user') { return 'USER-OID' }
            if ($Arguments -contains 'user.name')      { return '11111111-2222-3333-4444-555555555555' }
            if ($Arguments -contains 'sp')             { return 'SP-OID' }
            throw "unexpected az call: $($Arguments -join ' ')"
        }

        $threw = $false
        try { Assert-AzUserSession -What 'Creating the Computer Use connection' } catch { $threw = $true }
        $ok = ($threw -eq $case.Blocks)
        if (-not $ok) { $fail++ }
        '{0} {1,-18} assert kind={2,-17} blocked={3}' -f $(if ($ok) {'OK  '} else {'FAIL'}), $file, "'$($case.Kind)'", $threw

        if (-not $wantCaller) { continue }

        $got = try { Get-AzCallerIdentity } catch { $null }
        if ($null -eq $case.Type) {
            $ok = ($null -eq $got)
        } else {
            $ok = ($got -and $got.Type -eq $case.Type -and $got.Id -eq $case.Oid)
        }
        if (-not $ok) { $fail++ }
        '{0} {1,-18} caller kind={2,-17} -> {3}' -f $(if ($ok) {'OK  '} else {'FAIL'}), $file, "'$($case.Kind)'",
            $(if ($got) { "$($got.Type)/$($got.Id)" } else { 'threw' })
    }
}

$expect = @{
    'Prepare-Sol.ps1'     = @('connection in an environment')
    'Machine-and-Cua.ps1' = @('Creating the Computer Use connection', 'Step 4.4, setting the agent authentication to Custom Entra')
    'Run-HandOver.ps1'    = @('connection in an environment', 'Creating the Computer Use connection', 'Step 4.4, setting the agent authentication to Custom Entra')
}
foreach ($file in $expect.Keys) {
    $ast  = [System.Management.Automation.Language.Parser]::ParseFile("$dir\$file", [ref]$null, [ref]$null)
    $text = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                             $args[0].GetCommandName() -eq 'Assert-AzUserSession' }, $true) |
              ForEach-Object { $_.Extent.Text })
    foreach ($w in $expect[$file]) {
        $hit = @($text | Where-Object { $_ -like "*$w*" }).Count -eq 1
        if (-not $hit) { $fail++ }
        '{0} {1,-18} guarded: {2}' -f $(if ($hit) {'OK  '} else {'FAIL'}), $file, $w
    }
}

if ($fail) { Write-Host "`n$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nall passed - app-only works for the key vault, and the three human-only steps fail fast" -ForegroundColor Green
