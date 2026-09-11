$ErrorActionPreference = 'Stop'
$dir  = $PSScriptRoot
$file = 'Run-HandOver.ps1'
$fail = 0

$ast = [System.Management.Automation.Language.Parser]::ParseFile("$dir\$file", [ref]$null, [ref]$null)
foreach ($name in 'Invoke-Az', 'Get-AzSessionKind', 'Connect-AzCli') {
    $fn = ($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                          $args[0].Name -eq $name }, $true))[0]
    if (-not $fn) { Write-Host "FAIL $file - $name not found" -ForegroundColor Red; exit 1 }
    . ([scriptblock]::Create($fn.Extent.Text))
}

function Write-Info { param([string] $m) }
function Write-Ok   { param([string] $m) }

function az {
    $line = $args -join ' '
    $script:calls += $line
    $global:LASTEXITCODE = 0
    switch -Regex ($line) {
        'account show .*tenantId' {
            if (-not $script:session) { $global:LASTEXITCODE = 1; return }
            return $script:session
        }
        'account show .*user\.type' {
            if (-not $script:session) { $global:LASTEXITCODE = 1; return }
            return 'user'
        }
        'account show .*user\.name' { return 'someone@example.com' }
        '^login'                    { $script:session = $script:loginGives; return }
        "account list .*\?id=="     { if ($script:subs -contains $script:want) { return $script:want }; return }
        'account list .*id,name'    { return ($script:subs -join "`n") }
        'account set'               { return }
    }
}

function Invoke-Case {
    param([string] $Name, [string] $Session, [string] $Tenant, [string] $Sub,
          [string[]] $Subs = @(), [string] $LoginGives, [bool] $WantThrow, [bool] $WantLogin)
    $script:calls      = @()
    $script:session    = $Session
    $script:subs       = $Subs
    $script:want       = $Sub
    $script:loginGives = if ($LoginGives) { $LoginGives } else { $Tenant }

    $threw = $false
    try { Connect-AzCli -Tenant $Tenant -Subscription $Sub } catch { $threw = $true }
    $loggedIn = [bool]@($script:calls | Where-Object { $_ -like 'login*' }).Count
    $setSub   = [bool]@($script:calls | Where-Object { $_ -like 'account set*' }).Count

    $ok = ($threw -eq $WantThrow) -and ($loggedIn -eq $WantLogin) -and (-not $threw -and $Sub ? $setSub : $true)
    if (-not $ok) { $script:fail++ }
    '{0} {1,-42} threw={2,-5} login={3,-5} set={4}' -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $Name, $threw, $loggedIn, $setSub
}

$T  = 'cc7374ac-e69f-4e98-942a-1023569972ad'
$T2 = '11111111-2222-3333-4444-555555555555'
$S  = '0c33fa37-4fa1-466d-a891-46af9e2f6e44'

Invoke-Case 'right tenant already - no login'    -Session $T  -Tenant $T -Sub $S -Subs @($S) -WantThrow $false -WantLogin $false
Invoke-Case 'no session - logs in'               -Session ''  -Tenant $T -Sub $S -Subs @($S) -WantThrow $false -WantLogin $true
Invoke-Case 'wrong tenant - logs in again'       -Session $T2 -Tenant $T -Sub $S -Subs @($S) -WantThrow $false -WantLogin $true
Invoke-Case 'login lands on wrong tenant'        -Session ''  -Tenant $T -Sub $S -Subs @($S) -LoginGives $T2 -WantThrow $true -WantLogin $true
Invoke-Case 'subscription not visible'           -Session $T  -Tenant $T -Sub $S -Subs @()   -WantThrow $true  -WantLogin $false
Invoke-Case 'other subs visible, not this one'   -Session $T  -Tenant $T -Sub $S -Subs @('aaaaaaaa-1111-2222-3333-444444444444') -WantThrow $true -WantLogin $false
Invoke-Case 'no subscription asked for'          -Session $T  -Tenant $T -Sub ''  -Subs @()  -WantThrow $false -WantLogin $false

if ($fail) { Write-Host "`n$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nall passed - an existing session on the right tenant is reused, and an invisible subscription fails before anything is created" -ForegroundColor Green
