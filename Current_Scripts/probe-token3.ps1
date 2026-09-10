# Last question on the token path: the exchange rejected a Graph-audience token
# on audience validation, and az cannot mint one for the connector's own app
# (AADSTS65002, preauthorization, Microsoft-side). So try the audiences az CAN
# mint and see whether any of them satisfies the exchange.
# Cleans up every connection it makes, including the one left by probe-token2.
$ErrorActionPreference = 'Continue'
$envId = 'e1035d94-a890-eee7-8688-24702427f70a'
$f     = '&%24filter=' + [uri]::EscapeDataString("environment eq '$envId'")
$base  = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/shared_sharepointonline/connections'
$h     = @{ Authorization = "Bearer $(az account get-access-token --resource 'https://service.powerapps.com/' --query accessToken -o tsv)"
            Accept        = 'application/json' }

$made = @()
foreach ($res in 'https://apihub.azure.com',
                 'https://global.consent.azure-apim.net',
                 'https://inferifidemoorganization.sharepoint.com') {
    $tok = az account get-access-token --resource $res --query accessToken -o tsv 2>$null
    if (-not $tok) { Write-Host ("{0,-48} no token" -f $res); continue }

    $id  = 'shared-sharepointonl-' + [Guid]::NewGuid()
    $url = "$base/${id}?api-version=2016-11-01$f"
    $made += $url
    $body = @{ properties = @{
        displayName          = 'probe-aud-delete-me'
        environment          = @{ id = "/providers/Microsoft.PowerApps/environments/$envId"; name = $envId }
        connectionParameters = @{ token = @{ value = $tok } }
    } } | ConvertTo-Json -Depth 12

    try { $r = Invoke-RestMethod -Method Put -Uri $url -Headers $h -ContentType 'application/json' -Body $body }
    catch { Write-Host ("{0,-48} PUT failed: {1}" -f $res, $_.Exception.Message); continue }

    try {
        $t = Invoke-RestMethod -Uri $r.properties.testLinks[0].requestUri -Headers $h
        Write-Host ("{0,-48} RUNTIME OK - {1} site(s)" -f $res, (@($t.value)).Count) -ForegroundColor Green
    } catch {
        $m = $_.ErrorDetails.Message
        $why = if ($m -match '"message"\s*:\s*"([^"]+)"') { $Matches[1] } else { $_.Exception.Message }
        Write-Host ("{0,-48} {1}" -f $res, $why)
    }
}

Write-Host "`ncleaning up"
foreach ($u in $made) { try { Invoke-RestMethod -Method Delete -Uri $u -Headers $h | Out-Null } catch {} }
# and the one probe-token2 deliberately left behind
$stale = "$base/shared-sharepointonl-81fcefd1-8021-45ab-bd98-dbc7bf6220f1?api-version=2016-11-01$f"
try { Invoke-RestMethod -Method Delete -Uri $stale -Headers $h | Out-Null; Write-Host "  removed probe-token-runtime" } catch {}
