<#
.SYNOPSIS
    SailPoint ISC Automated Access Request Engine
.DESCRIPTION
    Reads a CSV input, validates identity uniqueness via /v2026/public-identities,
    resolves target Role IDs via /v2026/roles, and submits requests via /v2026/access-requests.
#>

# ==============================================================================
# CONFIGURATION PARAMETERS (HARDCODED)
# ==============================================================================
$execLoc       = 'C:\Users\greg_\...'
$CsvPath       = "$execLoc\AccessRequests_Input.csv'"
$LogDir        = 'C:\Users\greg_\...\Logs'
$SuccessLog    = "$LogDir\AccessRequest_Success.log"
$FailedLog     = "$LogDir\AccessRequest_Failure.log"

$TargetAttr    = 'identificationNumber'
$Tenant        = 'partner12798'
$Domain        = 'identitynow-demo'
$ClientId      = 'CLIENT_ID'
$ClientSecret  = 'CLIENT_SECRET'
# ==============================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web

# 1. PRE-FLIGHT LOGGING INITIALIZATION
# If log directory or files cannot be written, execution strictly halts.
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

# 2. CSV FILE ACCESSIBILITY CHECK
if (-not (Test-Path -Path $CsvPath)) {
    $err = "[FATAL ERROR] Input CSV file not found at location: $CsvPath"
    Write-Host $err -ForegroundColor Red
    $err | Out-File -FilePath $FailedLog -Append -Encoding utf8
    exit 1
}

# 3. OAUTH2 TOKEN ACQUISITION (/oauth/token)
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

# 4. PROCESS CSV ROWS ITERATIVELY
Get-Content -Path $CsvPath |
    Select-Object -Skip 1 |
    ForEach-Object {
    $attrValue, $roleName = $_ -split ',', 2

    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "Target Attr ($TargetAttr): '$attrValue' | Requested Role: '$roleName'" -ForegroundColor Cyan

    # Check for empty fields
    if ([string]::IsNullOrWhiteSpace($attrValue) -or [string]::IsNullOrWhiteSpace($roleName)) {
        $logMsg = "[DATA ERROR] Row missing values for $TargetAttr or Role Name. Skipping row."
        Write-Host $logMsg -ForegroundColor Yellow
        $logMsg | Out-File -FilePath $FailedLog -Append -Encoding utf8
        continue
    }

    try {
        # Identity Search via /v2026/search
        $idUrl = "https://$Tenant.api.$Domain.com/v2026/search"
        $body = @"
{
  `"indices`": [
    `"identities`"
  ],
  `"query`": {
    `"query`": `"attributes.$TargetAttr eq `\`"$attrValue`\`"`"
  }
}
"@
        $identities = Invoke-RestMethod -Uri $idUrl -Method Post -Headers $headers -Body $body

        if ((@($identities)).Count -eq 0) {
            throw "Identity not found for $TargetAttr = $attrValue"
        }
        elseif ((@($identities)).Count -gt 1) {
            throw "Non-unique identity error. Found $(@($identities).Count) matches for $TargetAttr = $attrValue"
        }
        $targetIdentityId = $identities[0].id

        # Write-Host "[INFO] Identity ID: $targetIdentityId" -ForegroundColor Green

        # Role ID Lookup via /v2026/roles
        $roleFilter = "name eq `"$roleName`""
        $roleUrl = "https://$Tenant.api.identitynow-demo.com/v2026/roles?filters=" + [System.Web.HttpUtility]::UrlEncode($roleFilter)
        $roles = Invoke-RestMethod -Uri $roleUrl -Method Get -Headers $headers

        if ((@($roles)).Count -eq 0) {
            throw "Target Role named `"$roleName`" could not be resolved."
        }
        $targetRoleId = $roles[0].id

        # Write-Host "[INFO] Role ID: $targetRoleId" -ForegroundColor Green

        # Submit Access Request via /v2026/access-requests
        $reqUrl = "https://$Tenant.api.$Domain.com/v2026/access-requests"
$body = @"
{
    `"requestedFor`": [
        `"$targetIdentityId`"
    ],
    `"requestedItems`": [
        {
            `"id`": `"$targetRoleId`",
            `"type`": `"ROLE`",
            `"comment`": `"Automated access request executed via PowerShell.`"
        }
    ],
    `"requestType`": `"GRANT_ACCESS`"`
}
"@

        $response = Invoke-RestMethod $reqUrl -Method 'POST' -Headers $headers -Body $body
        if ($response.newRequests -and $response.newRequests[0].accessRequestIds) {
            $accessRequestId = $response.newRequests[0].accessRequestIds[0]
        
            $successMsg = "[SUCCESS] Attribute Value: [$attrValue] | Role: [$roleName] | Request ID: $accessRequestId"
            Write-Host $successMsg -ForegroundColor Green
            $response | Out-File -FilePath $SuccessLog -Append -Encoding utf8
        }  
    } catch {
        $failMsg = "[FAILED] Attribute Value: [$attrValue] | Role: [$roleName] | Reason: $($_.Exception.Message)"

        Write-Host $failMsg -ForegroundColor Red
        $failMsg | Out-File -FilePath $FailedLog -Append -Encoding utf8
    }
}

Write-Host '[COMPLETE] Processing cycle finished. Check log files for details.' -ForegroundColor Cyan
