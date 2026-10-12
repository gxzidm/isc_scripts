<#
.SYNOPSIS
    SailPoint ISC Flat File Disconnected Account CSV Generator & Automated Source Aggregation Engine
.DESCRIPTION
    1. Authenticates to SailPoint ISC via OAuth2 Client Credentials grant (/oauth/token).
    2. Resolves target Source ID by name via GET /v2026/sources.
    3. Fetches all Entitlements owned by the target Source via GET /v2026/entitlements to build an authoritative Entitlement Lookup Map.
    4. Searches for Roles carrying the target Tag Value via POST /v2026/search.
    5. Cross-references Role entitlement assignments against the Source Entitlement Lookup Map to map Role IDs to Entitlement Values.
    6. Resolves identities holding those tagged roles via POST /v2026/search.
    7. Inspects $identity.access for assigned tagged roles, derives the target source entitlements from memory, and exports the CSV.
    8. Uploads the generated CSV payload via POST /v2026/sources/{id}/load-accounts if configured.
#>

# ==============================================================================
# CONFIGURATION PARAMETERS (HARDCODED)
# ==============================================================================
$TagValue            = 'ZAJAC'                                    # Tag value to search roles for
$SourceName          = 'Zajac - Unconnected System'               # Target Flat File Source Name in ISC
$IdentityIdAttribute = 'name'                                     # Attribute used for 'id' and 'name' (e.g., 'name', 'uid')
$MultiValueDelimiter = ','                                        # Comma-separated entitlement output
$aggregateCSV        = $false                                     # Set to $true to trigger unoptimized aggregation after CSV generation

$execLoc       = 'C:\Users\greg_\...'
$OutputFile    = "$execLoc\SailPoint.csv"

$LogDir        = 'C:\Users\greg_\...\Logs'
$SuccessLog    = "$LogDir\Zajac_AccountAggregation_Success.log"
$FailedLog     = "$LogDir\Zajac_AccountAggregation_Failure.log"

$Tenant        = 'partner12798'
$Domain        = 'identitynow-demo'
$ClientId      = 'CLIENT_ID'
$ClientSecret  = 'CLIENT_SECRET'
# ==============================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web

# 1. PRE-FLIGHT LOGGING INITIALIZATION
try {
    if (-not (Test-Path -Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    $timeStamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "=== START EXECUTION SESSION: $timeStamp ===" | Out-File -FilePath $SuccessLog -Append -Encoding utf8
    "=== START EXECUTION SESSION: $timeStamp ===" | Out-File -FilePath $FailedLog -Append -Encoding utf8
} catch {
    Write-Host "[FATAL CRITICAL ERROR] Unable to create or write to log files. Execution strictly halted." -ForegroundColor Red
    Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 3. OAUTH2 TOKEN ACQUISITION (/oauth/token)
try {
    $tokenUrl = "https://$Tenant.api.identitynow.com/oauth/token"
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
    }
    $authResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded'
    $accessToken = $authResponse.access_token
    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type'  = 'application/json'
    }
} catch {
    $err = "[FATAL ERROR] Authentication failed against SailPoint ISC API. $($_.Exception.Message)"
    Write-Host $err -ForegroundColor Red
    $err | Out-File -FilePath $FailedLog -Append -Encoding utf8
    exit 1
}

Write-Host "------------------------------------------------------------" -ForegroundColor Gray
Write-Host "[INFO] Authentication successful. Access token acquired." -ForegroundColor Green

# 3. MAIN WORKFLOW
try {
    # Step A: Resolve Target Source ID by Source Name upfront (/v2026/sources)
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "[+] Resolving Target Source ID for Source Name '$SourceName'..." -ForegroundColor Cyan
    
    $sourceFilter = "name eq `"$SourceName`""
    $sourceUrl = "https://$Tenant.api.identitynow.com/v2026/sources?filters=" + [System.Web.HttpUtility]::UrlEncode($sourceFilter)
    $sources = Invoke-RestMethod -Uri $sourceUrl -Method Get -Headers $headers

    if ($null -eq $sources -or (@($sources)).Count -eq 0) {
        throw "Target Source named `"$SourceName`" could not be resolved."
    }

    $targetSourceId = $sources[0].id
    Write-Host "[SUCCESS] Target Source ID resolved: [$targetSourceId]" -ForegroundColor Green

    # Step B: Fetch All Entitlements for Target Source (/v2026/entitlements)
    Write-Host "[+] Fetching entitlement definitions for Source [$targetSourceId]..." -ForegroundColor Cyan
    $entFilter = "source.id eq `"$targetSourceId`""
    $entUrl = "https://$Tenant.api.identitynow.com/v2026/entitlements?filters=" + [System.Web.HttpUtility]::UrlEncode($entFilter) + "&limit=250"
    $sourceEntitlements = Invoke-RestMethod -Uri $entUrl -Method Get -Headers $headers

    # Build Map: Entitlement ID -> Entitlement Value
    $sourceEntitlementMap = @{}
    if ($sourceEntitlements) {
        foreach ($se in $sourceEntitlements) {
            $val = if ($se.value) { $se.value } elseif ($se.name) { $se.name } else { $se.id }
            $sourceEntitlementMap[$se.id] = $val
        }
    }
    Write-Host "[SUCCESS] Cached $($sourceEntitlementMap.Count) entitlement definition(s) for source '$SourceName'." -ForegroundColor Green

    # Step C: Search for Roles Tagged with $TagValue (/v2026/search)
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "[+] Searching for Roles tagged with '$TagValue'..." -ForegroundColor Cyan
    
    $roleSearchBody = @{
        query = @{
            query = "tags:$TagValue"
        }
        indices = @("roles")
    } | ConvertTo-Json -Depth 5

    $searchUrl = "https://$Tenant.api.identitynow.com/v2026/search"
    $searchHeaders = $headers.Clone()
    $searchHeaders['Content-Type'] = 'application/json'

    $roles = Invoke-RestMethod -Uri $searchUrl -Method Post -Headers $searchHeaders -Body $roleSearchBody

    if ($null -eq $roles -or (@($roles)).Count -eq 0) {
        $msg = "[WARNING] No roles found matching tag '$TagValue'."
        Write-Host $msg -ForegroundColor Yellow
        $msg | Out-File -FilePath $FailedLog -Append -Encoding utf8
        exit 0
    }

    # Map Role ID -> HashSet of Target Source Entitlement Values
    $taggedRoleIds     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $roleToEntValueMap = @{}

    foreach ($role in $roles) {
        [void]$taggedRoleIds.Add($role.id)
        
        $roleUrl = "https://$Tenant.api.identitynow.com/v2026/roles/$($role.id)"
        $roleDetail = Invoke-RestMethod -Uri $roleUrl -Method Get -Headers $headers
        
        $roleEntSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        if ($roleDetail.entitlements) {
            foreach ($ent in $roleDetail.entitlements) {
                # Check if this role entitlement exists in our cached Source Entitlement Map
                if ($sourceEntitlementMap.ContainsKey($ent.id)) {
                    [void]$roleEntSet.Add($sourceEntitlementMap[$ent.id])
                }
            }
        }
        $roleToEntValueMap[$role.id] = $roleEntSet
    }

    Write-Host "[SUCCESS] Processed $(@($roles).Count) role(s) carrying tag '$TagValue'." -ForegroundColor Green

    # Step D: Search Identities holding the Tagged Roles (/v2026/search)
    $roleQueryParts  = $taggedRoleIds | ForEach-Object { "@access(id:`"$_`")" }
    $roleQueryString = "(" + ($roleQueryParts -join " OR ") + ")"

    $identitySearchBody = @{
        query = @{
            query = $roleQueryString
        }
        indices = @("identities")
    } | ConvertTo-Json -Depth 5

    Write-Host "[+] Searching for Identities holding tagged roles..." -ForegroundColor Cyan
    $identities = Invoke-RestMethod -Uri $searchUrl -Method Post -Headers $searchHeaders -Body $identitySearchBody

    if ($null -eq $identities -or (@($identities)).Count -eq 0) {
        $msg = "[WARNING] No identities found holding the tagged roles."
        Write-Host $msg -ForegroundColor Yellow
    } else {
        Write-Host "[SUCCESS] Found $(@($identities).Count) target identity/identities." -ForegroundColor Green
    }

    # Step E: Construct Account Objects & Derive Disconnected Entitlements
    $csvRecords = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($identities) {
        foreach ($identity in $identities) {
            # Extract identity account identifier
            $idVal = $identity.$IdentityIdAttribute
            if (-not $idVal) {
                $idVal = $identity.name
            }

            if ($identity.access) {
                foreach ($accessItem in $identity.access) {
                    if ($accessItem.type -eq 'ROLE' -and $taggedRoleIds.Contains($accessItem.id)) {
                        if ($roleToEntValueMap.ContainsKey($accessItem.id)) {
                            foreach ($val in $roleToEntValueMap[$accessItem.id]) {
                                # Build account row
                                    $csvRecords.Add([PSCustomObject]@{
                                        id                = $idVal
                                        name              = $idVal
                                        groups            = $val
                                })
                            }
                        }
                    }
                }
            }
        }
    }

    # Step F: Export Data to CSV Payload
    if ($csvRecords.Count -gt 0) {
        $csvRecords | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
        Write-Host "[SUCCESS] Exported $($csvRecords.Count) record(s) to '$OutputFile'." -ForegroundColor Green
    } else {    
        '"id","name","groups"' | Out-File -FilePath $OutputFile -Encoding ascii -Force
        Write-Host "[INFO] Zero records derived. Wrote default header structure to '$OutputFile'." -ForegroundColor Yellow
    }
    
    $successMsg = "[SUCCESS] Generated Flat File CSV at '$OutputFile' with $($csvRecords.Count) account records."
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    Write-Host $successMsg -ForegroundColor Green
    $successMsg | Out-File -FilePath $SuccessLog -Append -Encoding utf8

    if (-not $aggregateCSV) {
        Write-Host "------------------------------------------------------------" -ForegroundColor Gray
        Write-Host "[INFO] CSV generation completed. Unoptimized aggregation skipped as per configuration." -ForegroundColor Cyan
        exit 0
    }

    # Step G: Upload CSV File & Trigger Unoptimized Aggregation (/v2026/sources/{id}/load-accounts)
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "[+] Uploading CSV file and triggering account aggregation for source [$targetSourceId]..." -ForegroundColor Cyan
    
    $uploadUrl = "https://$Tenant.api.identitynow.com/v2026/sources/$targetSourceId/load-accounts"

    $httpClient = [System.Net.Http.HttpClient]::new()
    $httpClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $accessToken)

    $formContent = [System.Net.Http.MultipartFormDataContent]::new()
    $fileBytes   = [System.IO.File]::ReadAllBytes($OutputFile)
    $byteArrayContent = [System.Net.Http.ByteArrayContent]::new($fileBytes)
    $byteArrayContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('text/csv')

    $formContent.Add($byteArrayContent, 'file', [System.IO.Path]::GetFileName($OutputFile))
    
    $stringContent = [System.Net.Http.StringContent]::new('true')
    $formContent.Add($stringContent, 'disableOptimization')

    $uploadResponse = $httpClient.PostAsync($uploadUrl, $formContent).GetAwaiter().GetResult()
    $responseBody   = $uploadResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    if ($uploadResponse.IsSuccessStatusCode) {
        $aggSuccessMsg = "[SUCCESS] Account aggregation triggered successfully for Source [$SourceName]. Task Payload:`n$responseBody"
        Write-Host $aggSuccessMsg -ForegroundColor Green
        $aggSuccessMsg | Out-File -FilePath $SuccessLog -Append -Encoding utf8
    } else {
        throw "Aggregation upload failed with HTTP status code $($uploadResponse.StatusCode):$responseBody"
    }

} catch {
    $failMsg = "[FAILED] Execution Cycle | Reason: $($_.Exception.Message)"
    Write-Host $failMsg -ForegroundColor Red
    $failMsg | Out-File -FilePath $FailedLog -Append -Encoding utf8
} finally {
    if ($httpClient) {$httpClient.Dispose() }
}

Write-Host "------------------------------------------------------------" -ForegroundColor Gray
Write-Host '[COMPLETE] Flat File CSV extraction and aggregation cycle finished. Check log files for details.' -ForegroundColor Cyan
