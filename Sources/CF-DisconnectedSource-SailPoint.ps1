<#
.SYNOPSIS
    SailPoint ISC Flat File Disconnected Account CSV Generator & Automated Source Aggregation Engine
.DESCRIPTION
    1. Authenticates to SailPoint ISC via OAuth2 Client Credentials grant (/oauth/token)[cite: 2].
    2. Resolves target Source ID by name via GET /v2026/sources[cite: 2].
    3. Fetches all Entitlements owned by the target Source via GET /v2026/entitlements to build an authoritative Entitlement Lookup Map[cite: 2].
    4. Resolves Roles containing target source entitlements using direct Entitlement ID matching in Search, with an automated fallback to /v2026/roles and Access Profile inspection[cite: 2].
    5. Resolves identities holding those roles via POST /v2026/search using @access(id:"ROLE_ID")[cite: 2].
    6. Inspects $identity.access for assigned roles, derives target source entitlements, and exports a clean CSV payload[cite: 2].     7. Evaluates$DryRun: If $true, execution halts after CSV generation; if$false (and $aggregateCSV =$true), uploads payload via POST /v2026/sources/{id}/load-accounts[cite: 2].
#>

# ==============================================================================
# CONFIGURATION PARAMETERS (HARDCODED)
# ==============================================================================
$SourceName          = 'SailPoint'                                          # Target Flat File Source Name in ISC[cite: 2]
$IdentityIdAttribute = 'name'                                               # Attribute used for 'id' and 'name' (e.g., 'name', 'uid')[cite: 2]
$DryRun              =  $true                                               # Set to $true to generate CSV only (stops actual API aggregation)
$aggregateCSV        =  $false                                              # Set to $true to trigger unoptimized aggregation after CSV generation (ignored if $DryRun =$true)[cite: 2]

$execLoc            = 'C:\Users\greg_\...'                                  #[cite: 2]
$OutputFile         = "$execLoc\Coupa.csv"                              #[cite: 2]

$LogDir             = 'C:\Users\greg_\...\Logs'                             #[cite: 2]
$SuccessLog         = "$LogDir\Coupa_AccountAggregation_Success.log"    #[cite: 2]
$FailedLog          = "$LogDir\Coupa_AccountAggregation_Failure.log"    #[cite: 2]

$Tenant             = 'cfi-sb'                                              #[cite: 2]
$Domain             = 'identitynow'                                         #[cite: 2]
$ClientId           = 'CFI SBX CLIENT ID'                                   #[cite: 2]
$ClientSecret       = 'CFI SBX CLIENT SECRET'                               #[cite: 2]
# ==============================================================================

$ErrorActionPreference = 'Stop'                                   #[cite: 2]
Add-Type -AssemblyName System.Web                                 #[cite: 2]

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

# 2. OAUTH2 TOKEN ACQUISITION (/oauth/token)
try {
    $tokenUrl = "https://$Tenant.api.$Domain.com/oauth/token"
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
    $sourceUrl = "https://$Tenant.api.$Domain.com/v2026/sources?filters=" + [System.Web.HttpUtility]::UrlEncode($sourceFilter)
    $sources = Invoke-RestMethod -Uri $sourceUrl -Method Get -Headers $headers

    if ($null -eq $sources -or (@($sources)).Count -eq 0) {
        throw "Target Source named `"$SourceName`" could not be resolved."
    }

    $targetSourceId =$sources[0].id
    Write-Host "[SUCCESS] Target Source ID resolved: [$targetSourceId]" -ForegroundColor Green

    # Step B: Fetch All Entitlements for Target Source (/v2026/entitlements)
    Write-Host "[+] Fetching entitlement definitions for Source [$targetSourceId]..." -ForegroundColor Cyan
    $entFilter = "source.id eq `"$targetSourceId`""
    $entUrl = "https://$Tenant.api.$Domain.com/v2026/entitlements?filters=" + [System.Web.HttpUtility]::UrlEncode($entFilter) + "&limit=250"
    $sourceEntitlements = Invoke-RestMethod -Uri $entUrl -Method Get -Headers $headers

    # Build Map: Entitlement ID -> Entitlement Value
    $sourceEntitlementMap = @{}
    if ($sourceEntitlements) {
        foreach ($se in $sourceEntitlements) {$val = if ($se.value) {$se.value } elseif ($se.name) {$se.name } else { $se.id }$sourceEntitlementMap[$se.id] =$val
        }
    }
    Write-Host "[SUCCESS] Cached $($sourceEntitlementMap.Count) entitlement definition(s) for source '$SourceName'." -ForegroundColor Green

    if ($sourceEntitlementMap.Count -eq 0) {$msg = "[WARNING] No entitlements exist for source '$SourceName'. Proceeding with blank CSV output."
        Write-Host $msg -ForegroundColor Yellow
        $msg | Out-File -FilePath $FailedLog -Append -Encoding utf8
    }

    # Step C: Search for Roles Referencing Source Entitlements (/v2026/search)
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "[+] Resolving Roles referencing Source [$targetSourceId] entitlements..." -ForegroundColor Cyan

    $roles = @()

    if ($sourceEntitlementMap.Count -gt 0) {
        # Construct search query matching cached entitlement IDs from target source
        $entIdList   =$sourceEntitlementMap.Keys | ForEach-Object { "`"$_`"" }
        $entIdJoined = $entIdList -join ' OR '
        $roleSearchQuery = "(entitlements.id:($entIdJoined)) OR (accessProfiles.entitlements.id:($entIdJoined)) OR (entitlements.source.id:`"$targetSourceId`")"

        $roleSearchBody = @{
            query = @{
                query = $roleSearchQuery
            }
            indices = @("roles")
        } | ConvertTo-Json -Depth 5

        $searchUrl = "https://$Tenant.api.$Domain.com/v2026/search"
        $searchHeaders = $headers.Clone()
        $searchHeaders['Content-Type'] = 'application/json'

        $roles = Invoke-RestMethod -Uri $searchUrl -Method Post -Headers $searchHeaders -Body $roleSearchBody
    }

    # FAIL-SAFE FALLBACK: If Search API returns 0 results, scan roles endpoint directly (/v2026/roles)
    if ($null -eq $roles -or (@($roles)).Count -eq 0) {
        Write-Host "[!] Search API returned 0 roles. Initiating fail-safe scan via GET /v2026/roles..." -ForegroundColor Yellow
        $allRolesUrl = "https://$Tenant.api.$Domain.com/v2026/roles?limit=250"
        $roles = Invoke-RestMethod -Uri $allRolesUrl -Method Get -Headers $headers
    }

    # Map Role ID -> HashSet of Target Source Entitlement Values
    $targetRoleIds     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $roleToEntValueMap = @{}

    if ($roles) {
        foreach ($role in $roles) {$roleUrl = "https://$Tenant.api.$Domain.com/v2026/roles/$($role.id)"
            $roleDetail = Invoke-RestMethod -Uri $roleUrl -Method Get -Headers $headers
            $roleEntSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            # 1. Check direct role entitlements
            if ($roleDetail.entitlements) {
                foreach ($ent in $roleDetail.entitlements) {
                    if ($sourceEntitlementMap.ContainsKey($ent.id)) {
                        [void]$roleEntSet.Add($sourceEntitlementMap[$ent.id])
                    }
                }
            }

            # 2. Check entitlements within attached Access Profiles
            if ($roleDetail.accessProfiles) {
                foreach ($ap in $roleDetail.accessProfiles) {$apUrl = "https://$Tenant.api.$Domain.com/v2026/access-profiles/$($ap.id)"
                    $apDetail = Invoke-RestMethod -Uri $apUrl -Method Get -Headers $headers
                    if ($apDetail.entitlements) {
                        foreach ($ent in $apDetail.entitlements) {
                            if ($sourceEntitlementMap.ContainsKey($ent.id)) {
                                [void]$roleEntSet.Add($sourceEntitlementMap[$ent.id])
                            }
                        }
                    }
                }
            }

            # Only retain role if it contains entitlements tied to the target source
            if ($roleEntSet.Count -gt 0) {                 [void]$targetRoleIds.Add($role.id)
                $roleToEntValueMap[$role.id] =$roleEntSet
            }
        }
    }

    if ($targetRoleIds.Count -eq 0) {$msg = "[WARNING] Verified 0 roles containing entitlements for Source [$targetSourceId]."
        Write-Host $msg -ForegroundColor Yellow
        $msg | Out-File -FilePath $FailedLog -Append -Encoding utf8
    } else {
        Write-Host "[SUCCESS] Successfully matched $($targetRoleIds.Count) role(s) containing entitlements for source '$SourceName'." -ForegroundColor Green
    }

    # Step D: Search Identities holding the Target Roles (/v2026/search)
    $identities = @()
    if ($targetRoleIds.Count -gt 0) {
        $roleQueryParts  =$targetRoleIds | ForEach-Object { "@access(id:`"$_`")" }
        $roleQueryString = "(" + ($roleQueryParts -join " OR ") + ")"

        $identitySearchBody = @{
            query = @{
                query = $roleQueryString
            }
            indices = @("identities")
        } | ConvertTo-Json -Depth 5

        Write-Host "[+] Searching for Identities holding target roles..." -ForegroundColor Cyan
        $identities = Invoke-RestMethod -Uri $searchUrl -Method Post -Headers $searchHeaders -Body $identitySearchBody
    }

    if ($null -eq $identities -or (@($identities)).Count -eq 0) {
        $msg = "[WARNING] No identities found holding the target roles."
        Write-Host $msg -ForegroundColor Yellow
    } else {
        Write-Host "[SUCCESS] Found $(@($identities).Count) target identity/identities." -ForegroundColor Green
    }

    # Step E: Construct Account Objects & Derive Disconnected Entitlements
    $csvRecords = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($identities) {
        foreach ($identity in $identities) {$idVal = $identity.$IdentityIdAttribute
            if (-not $idVal) {
                $idVal =$identity.name
            }

            if ($identity.access) {
                foreach ($accessItem in $identity.access) {
                    if ($accessItem.type -eq 'ROLE' -and $targetRoleIds.Contains($accessItem.id)) {
                        if ($roleToEntValueMap.ContainsKey($accessItem.id)) {
                            foreach ($val in $roleToEntValueMap[$accessItem.id]) {$csvRecords.Add([PSCustomObject]@{
                                    id     = $idVal
                                    name   = $idVal
                                    groups = $val
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
        # Write hardcoded header first
        '"id","name","groups"' | Out-File -FilePath $OutputFile -Encoding ascii -Force
        
        # Convert objects to CSV strings in memory, skip header line, and append to file
        ($csvRecords | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1) | 
            Out-File -FilePath $OutputFile -Append -Encoding ascii
            
        Write-Host "[SUCCESS] Exported $($csvRecords.Count) record(s) to '$OutputFile'." -ForegroundColor Green
    } else {    
        '"id","name","groups"' | Out-File -FilePath $OutputFile -Encoding ascii -Force
        Write-Host "[INFO] Zero records derived. Wrote default header structure to '$OutputFile'." -ForegroundColor Yellow
    }
    
    $successMsg = "[SUCCESS] Generated Flat File CSV at '$OutputFile' with $($csvRecords.Count) account records."
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    Write-Host $successMsg -ForegroundColor Green
    $successMsg | Out-File -FilePath $SuccessLog -Append -Encoding utf8

    # --------------------------------------------------------------------------
    # DRY RUN / AGGREGATION GATEWAY
    # --------------------------------------------------------------------------
    if ($DryRun) {
        Write-Host "------------------------------------------------------------" -ForegroundColor Gray
        Write-Host "[DRY RUN] Execution halted as `$DryRun is set to `$true. File written to '$OutputFile' but aggregation API was not called." -ForegroundColor Yellow
        exit 0
    }

    if (-not $aggregateCSV) {
        Write-Host "------------------------------------------------------------" -ForegroundColor Gray
        Write-Host "[INFO] CSV generation completed. Unoptimized aggregation skipped as per `$aggregateCSV configuration." -ForegroundColor Cyan
        exit 0
    }

    # Step G: Upload CSV File & Trigger Unoptimized Aggregation (/v2026/sources/{id}/load-accounts)
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "[+] Uploading CSV file and triggering account aggregation for source [$targetSourceId]..." -ForegroundColor Cyan
    
    $uploadUrl = "https://$Tenant.api.$Domain.com/v2026/sources/$targetSourceId/load-accounts"

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
        $aggSuccessMsg | Out-File -FilePath$SuccessLog -Append -Encoding utf8
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