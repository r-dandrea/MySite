#Requires -Version 7.0
<#
.SYNOPSIS
    One-time setup: creates Entra App Registration for the CA Gap Analyzer web app.

.DESCRIPTION
    Creates a SPA app registration, adds Graph read permissions, grants admin consent,
    and writes web/.env + web/public/config.json.

    Then: cd web && npm run dev → Sign in with Microsoft (like joeyverlinden.com).

.PARAMETER RedirectUri
    SPA redirect URI for local dev. Default: http://localhost:5173

.PARAMETER ProductionRedirectUri
    Additional redirect URI for GitHub Pages / production (e.g. https://user.github.io/ca-scanner/)

.PARAMETER MultiTenant
    Register as multi-tenant (AzureADMultipleOrgs) so any customer tenant can sign in — like jhope188.

.EXAMPLE
    ./Register-CAAnalyzerApp.ps1 -MultiTenant -ProductionRedirectUri "https://<your-site>/tool/ca-policy-analyzer/"
#>
[CmdletBinding()]
Param(
    [string]$AppName = "CA Gap Analyzer",
    [string]$RedirectUri = "http://localhost:5173",
    [string]$ProductionRedirectUri = "",
    [switch]$MultiTenant
)

$ErrorActionPreference = 'Stop'
$GraphAppId = "00000003-0000-0000-c000-000000000000"

# Microsoft Graph delegated permission scope IDs (v1.0)
$ScopeNames = @(
    "Policy.Read.ConditionalAccess",
    "Group.Read.All",
    "Directory.Read.All",
    "Application.Read.All",
    "User.Read"
)

Write-Host "`n=== CA Gap Analyzer — App Registration ===" -ForegroundColor Cyan
Write-Host "Redirect URI: $RedirectUri`n"

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.Graph.Applications

Connect-MgGraph -Scopes Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All, Directory.ReadWrite.All -NoWelcome

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'" -Property Oauth2PermissionScopes, Id
$scopeIds = @()
foreach ($name in $ScopeNames) {
    $scope = $graphSp.Oauth2PermissionScopes | Where-Object { $_.Value -eq $name }
    if (-not $scope) { throw "Graph scope not found: $name" }
    $scopeIds += @{ Id = $scope.Id; Type = "Scope" }
    Write-Host "  + $name" -ForegroundColor DarkGray
}

$redirectUris = @($RedirectUri)
if ($ProductionRedirectUri) { $redirectUris += $ProductionRedirectUri }

$audience = if ($MultiTenant) { "AzureADMultipleOrgs" } else { "AzureADMyOrg" }
Write-Host "Audience: $audience`n" -ForegroundColor DarkGray

$app = New-MgApplication -DisplayName $AppName -SignInAudience $audience `
    -Web @{ RedirectUris = @(); ImplicitGrantSettings = @{ EnableIdTokenIssuance = $false } } `
    -Spa @{ RedirectUris = $redirectUris } `
    -RequiredResourceAccess @(@{ ResourceAppId = $GraphAppId; ResourceAccess = $scopeIds })

$tenantId = (Get-MgContext).TenantId
$sp = New-MgServicePrincipal -AppId $app.AppId

# Admin consent (all principals)
try {
    $existing = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($sp.Id)' and consentType eq 'AllPrincipals'" -ErrorAction SilentlyContinue
    if ($existing) {
        Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $existing.Id -Scope ($ScopeNames -join " ")
    } else {
        New-MgOauth2PermissionGrant -ClientId $sp.Id -ConsentType AllPrincipals `
            -PrincipalId $null -ResourceId $graphSp.Id -Scope ($ScopeNames -join " ")
    }
    Write-Host "Admin consent granted." -ForegroundColor Green
} catch {
    Write-Warning "Grant admin consent manually: Entra → App registrations → $AppName → API permissions → Grant admin consent"
}

$webDir = $PSScriptRoot
$envFile = Join-Path $webDir ".env"
$configFile = Join-Path $webDir "public" "config.json"

if ($MultiTenant) {
@"
VITE_AZURE_CLIENT_ID=$($app.AppId)
"@ | Set-Content -Path $envFile -Encoding utf8
} else {
@"
VITE_AZURE_CLIENT_ID=$($app.AppId)
VITE_AZURE_TENANT_ID=$tenantId
"@ | Set-Content -Path $envFile -Encoding utf8
}

@{ clientId = $app.AppId; tenantId = if ($MultiTenant) { $null } else { $tenantId }; multiTenant = [bool]$MultiTenant } | ConvertTo-Json | Set-Content -Path $configFile -Encoding utf8

Write-Host "`nTo ship 'click and go' like jhope188.github.io:" -ForegroundColor Cyan
Write-Host "  1. Put client ID in web/public/config.json (done) OR web/src/auth/hostedClient.ts"
Write-Host "  2. npm run build && deploy dist/ to GitHub Pages"
Write-Host "  3. Ensure redirect URI '$ProductionRedirectUri' is in Entra (added above if you passed -ProductionRedirectUri)"
Write-Host ""
Write-Host "  Client ID: $($app.AppId)"
Write-Host "  Tenant:    $tenantId"
Write-Host "  Files:     .env, public/config.json"
Write-Host "`nNow run:" -ForegroundColor Yellow
Write-Host "  cd web"
Write-Host "  npm run dev"
Write-Host "  → http://localhost:5173 → Sign in with Microsoft`n"

Disconnect-MgGraph | Out-Null
