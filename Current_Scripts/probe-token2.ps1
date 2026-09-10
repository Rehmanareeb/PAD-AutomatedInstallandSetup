$ErrorActionPreference = 'Continue'
$envId = 'e1035d94-a890-eee7-8688-24702427f70a'
$f = '&%24filter=' + [uri]::EscapeDataString("environment eq '$envId'")
$pa = az account get-access-token --resource 'https://service.powerapps.com/' --query accessToken -o tsv
$h  = @{ Authorization = "Bearer $pa"; Accept = 'application/json' }
$base = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/shared_sharepointonline/connections'

# customParameters on the connector name graph as the resource, so ask for that.
$graph = az account get-access-token --resource 'https://graph.microsoft.com/' --query accessToken -o tsv

$id  = 'shared-sharepointonl-' + [Guid]::NewGuid()
$url = "$base/${id}?api-version=2016-11-01$f"
$body = @{ properties = @{
    displayName          = 'probe-token-runtime'
    environment          = @{ id = "/providers/Microsoft.PowerApps/environments/$envId"; name = $envId }
    connectionParameters = @{ token = @{ value = $graph } }
} } | ConvertTo-Json -Depth 12

$r = Invoke-RestMethod -Method Put -Uri $url -Headers $h -ContentType 'application/json' -Body $body
Write-Host "status      : $($r.properties.statuses[0].status)"
Write-Host "created     : $($r.properties.createdTime)"
Write-Host "expires     : $($r.properties.expirationTime)"
Write-Host "authedUser  : $($r.properties.authenticatedUser | ConvertTo-Json -Compress)"
Write-Host "testLink    : $($r.properties.testLinks[0].requestUri)"

# The only proof that matters: can it actually reach SharePoint?
Write-Host "`n=== runtime call ==="
try {
    $t = Invoke-RestMethod -Uri $r.properties.testLinks[0].requestUri -Headers $h
    Write-Host "RUNTIME OK - returned $((@($t.value)).Count) item(s)"
    @($t.value) | Select-Object -First 3 | ForEach-Object {
        Write-Host "   $(if ($_.DisplayName) { $_.DisplayName } else { $_.Name })" }
} catch {
    $m = $_.ErrorDetails.Message
    Write-Host "RUNTIME FAILED: $($_.Exception.Message)"
    if ($m) { Write-Host $m.Substring(0, [Math]::Min(500, $m.Length)) }
}

Write-Host "`nleaving $id in place for inspection"
