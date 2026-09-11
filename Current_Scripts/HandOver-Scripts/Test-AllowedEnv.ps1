$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

$TENANT = 'cc7374ac-e69f-4e98-942a-1023569972ad'
$ENV1   = '20bbbb76-91c1-efde-bf32-8a5468336104'
$ENV2   = 'eaa3f01b-f9a9-ee0c-b124-b226cc662813'

$fail = 0
foreach ($file in 'Prepare-Sol.ps1', 'Run-HandOver.ps1') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$dir\$file", [ref]$null, [ref]$null)
    $fn  = ($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                           $args[0].Name -eq 'Resolve-AllowedEnvironments' }, $true))[0]
    if (-not $fn) { Write-Host "FAIL $file - Resolve-AllowedEnvironments not found" -ForegroundColor Red; $fail++; continue }
    . ([scriptblock]::Create($fn.Extent.Text))

    $cases = @(
        @{ Name = 'defaults to the environment id'; Tag = '';                  Env = $ENV1; Want = $ENV1 }
        @{ Name = 'this environment plus another';  Tag = "$ENV1,$ENV2";       Env = $ENV1; Want = "$ENV1,$ENV2" }
        @{ Name = 'whitespace trimmed';             Tag = "  $ENV1 , $ENV2 ";  Env = $ENV1; Want = "$ENV1,$ENV2" }
        @{ Name = 'no environment to check against'; Tag = "$ENV2";            Env = '';    Want = $ENV2 }
    )
    foreach ($c in $cases) {
        $got = try { Resolve-AllowedEnvironments -Tag $c.Tag -EnvironmentId $c.Env -TenantId $TENANT }
               catch { "THREW: $($_.Exception.Message.Split([char]10)[0])" }
        $ok = $got -eq $c.Want
        if (-not $ok) { $fail++ }
        '{0} {1,-34} {2,-20} {3}' -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $c.Name, $file, $got
    }

    $rejects = @(
        @{ Name = 'TENANT id rejected';              Tag = $TENANT;         Env = $ENV1 }
        @{ Name = 'tenant among envs rejected';      Tag = "$ENV1,$TENANT"; Env = $ENV1 }
        @{ Name = 'non-GUID rejected';               Tag = 'not-a-guid';    Env = $ENV1 }
        @{ Name = 'nothing to use rejected';         Tag = '';              Env = '' }
        @{ Name = 'stale tag for another env';       Tag = $ENV2;           Env = $ENV1 }
    )
    foreach ($r in $rejects) {
        $threw = $false
        try { Resolve-AllowedEnvironments -Tag $r.Tag -EnvironmentId $r.Env -TenantId $TENANT | Out-Null }
        catch { $threw = $true }
        if (-not $threw) { $fail++ }
        '{0} {1,-34} {2}' -f $(if ($threw) { 'OK  ' } else { 'FAIL' }), $r.Name, $file
    }
}

if ($fail) { Write-Host "`n$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nall passed - the tag defaults to the environment id, refuses the tenant id, and refuses a tag that omits this environment" -ForegroundColor Green
