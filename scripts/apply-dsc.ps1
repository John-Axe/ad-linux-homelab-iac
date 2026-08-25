#Requires -RunAsAdministrator

<#
    apply-dsc.ps1

    Vagrant shell-provisioner entry point for DC01. Installs the required
    DSC resource modules (if missing), compiles dsc/dc-configuration.ps1
    into a MOF, and applies it.

    Credentials are never hard-coded: the safe-mode DSRM password and the
    domain administrator password are read from environment variables and
    the script fails loudly if either is missing, rather than silently
    falling back to a default/blank password.

    For a real (non-lab) run, set these before `vagrant up dc01`:
        $env:AD_SAFEMODE_PASSWORD = "<strong, unique password>"
        $env:AD_ADMIN_PASSWORD    = "<strong, unique password>"
    or wire them from a secrets manager / CI secret store instead of a
    shell variable.
#>

[CmdletBinding()]
param(
    [string] $DomainName = "contoso.local",
    [string] $DcIpAddress = "10.10.10.10"
)

$ErrorActionPreference = "Stop"

if (-not $env:AD_SAFEMODE_PASSWORD -or -not $env:AD_ADMIN_PASSWORD) {
    throw "AD_SAFEMODE_PASSWORD and AD_ADMIN_PASSWORD must both be set in " +
          "the environment before applying dc-configuration.ps1. Refusing " +
          "to fall back to a default password."
}

$requiredModules = @(
    @{ Name = "xActiveDirectory"; Version = "3.0.0" },
    @{ Name = "xDnsServer";       Version = "2.0.0" },
    @{ Name = "xDhcpServer";      Version = "2.0.0" },
    @{ Name = "xNetworking";      Version = "5.7.0" }
)

foreach ($module in $requiredModules) {
    $installed = Get-Module -ListAvailable -Name $module.Name |
        Where-Object { $_.Version -eq [version]$module.Version }

    if (-not $installed) {
        Write-Host "Installing DSC resource module $($module.Name) $($module.Version)..."
        Install-Module -Name $module.Name -RequiredVersion $module.Version `
            -Force -SkipPublisherCheck -Scope AllUsers
    }
}

$safeModeSecure = ConvertTo-SecureString $env:AD_SAFEMODE_PASSWORD -AsPlainText -Force
$domainAdminSecure = ConvertTo-SecureString $env:AD_ADMIN_PASSWORD -AsPlainText -Force

$safeModeCred = [pscredential]::new("SafeModeAdmin", $safeModeSecure)
$domainAdminCred = [pscredential]::new("$($DomainName.Split('.')[0])\Administrator", $domainAdminSecure)

. "$PSScriptRoot\..\dsc\dc-configuration.ps1"

$outputPath = "C:\DSC\DomainController"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

DomainController -DomainName $DomainName `
    -SafeModeAdministratorCred $safeModeCred `
    -DomainAdminCred $domainAdminCred `
    -DcIpAddress $DcIpAddress `
    -OutputPath $outputPath

Set-DscLocalConfigurationManager -Path $outputPath -Verbose
Start-DscConfiguration -Path $outputPath -Wait -Verbose -Force
