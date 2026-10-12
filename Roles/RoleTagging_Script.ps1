<#
.SYNOPSIS
    SailPoint ISC Automated Role Tag Purge & Replace Engine
.DESCRIPTION
    Reads a CSV input (RoleName, Tags), resolves target Role IDs via /v2026/roles,
    purges existing tag objects via DELETE /v2026/tagged-objects/{id}, and posts
    the new pipe-delimited tag payload via POST /v2026/tagged-objects.
#>

# ==============================================================================
# CONFIGURATION PARAMETERS (HARDCODED)
# ==============================================================================
$execLoc       = 'C:\Users\greg_\...'
$CsvPath       = "$execLoc\RoleTags_Input.csv'"
$LogDir        = 'C:\Users\greg_\...\Logs'
$SuccessLog    = "$LogDir\RoleTagging_Success.log"
$FailedLog     = "$LogDir\RoleTagging_Failure.log"

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
    $roleName, $rawTags =$_ -split ',', 2

    Write-Host "------------------------------------------------------------" -ForegroundColor Gray

    # Check for empty fields
    if ([string]::IsNullOrWhiteSpace($roleName) -or [string]::IsNullOrWhiteSpace($rawTags)) {
        $logMsg = "[DATA ERROR] Row missing values for Role Name or Tags. Skipping row."
        Write-Host $logMsg -ForegroundColor Yellow
        $logMsg | Out-File -FilePath $FailedLog -Append -Encoding utf8
        continue
    }

    try {  
        # Step A: Resolve Role ID via /v2026/roles
        $roleFilter = "name eq `"$roleName`""
        $roleUrl = "https://$Tenant.api.$Domain.com/v2026/roles?filters=" + [System.Web.HttpUtility]::UrlEncode($roleFilter)
        $roles = Invoke-RestMethod -Uri $roleUrl -Method Get -Headers $headers

        if ((@($roles)).Count -eq 0) {
            throw "Target Role named `"$roleName`" could not be resolved."
        }
        $targetRoleId =$roles[0].id

        # Step B: Apply New Replacement Tags via /v2026/tagged-objects
        $tagUrl = "https://$Tenant.api.$Domain.com/v2026/tagged-objects/ROLE/$targetRoleId"

        # 1. Initialize a generic string list
        $tagList = [System.Collections.Generic.List[string]]::new()

        # 2. Split pipe-delimited raw input and iterate through each item
        foreach ($tag in ($rawTags -split '\|')) {
            $cleanTag = $tag.Trim()
            if (-not [string]::IsNullOrWhiteSpace($cleanTag)) {
                $tagList.Add($cleanTag)
            }
        }

        # 3. Build payload object and let ConvertTo-Json handle the array syntax
        $payloadObject = [PSCustomObject]@{
            objectRef = [PSCustomObject]@{
                id   = $targetRoleId
                type = 'ROLE'
                name = $roleName
            }
            tags      = $tagList.ToArray()
        }

        $body = $payloadObject | ConvertTo-Json -Depth 5
        $response = Invoke-RestMethod -Uri $tagUrl -Method Put -Headers $headers -Body $body

        $successMsg = "[SUCCESS] Role: [$roleName] | Replaced Tags: [$tagList]"
        Write-Host $successMsg -ForegroundColor Green
        ($response | ConvertTo-Json -Compress) | Out-File -FilePath $SuccessLog -Append -Encoding utf8

    } catch {
        $failMsg = "[FAILED] Role: [$roleName] | Reason: $($_.Exception.Message)"
        Write-Host $failMsg -ForegroundColor Red
        $failMsg | Out-File -FilePath $FailedLog -Append -Encoding utf8
    }
}

Write-Host "------------------------------------------------------------" -ForegroundColor Gray
Write-Host '[COMPLETE] Tag processing cycle finished. Check log files for details.' -ForegroundColor Cyan