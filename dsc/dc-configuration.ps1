#Requires -Modules xActiveDirectory, xDnsServer, xDhcpServer, xNetworking

<#
    dc-configuration.ps1

    Desired State Configuration for DC01 — promotes a fresh Windows Server
    box to a domain controller for the lab domain, configures the AD-
    integrated DNS zone with an external forwarder, and stands up a DHCP
    scope for the client VLAN described in the reference topology
    (network-lab/topology.md in it-helpdesk-sysadmin-portfolio):

        VLAN 10 — Server/Infra   10.10.10.0/24   (this DC: 10.10.10.10)
        VLAN 20 — Clients        10.10.20.0/24   (DHCP scope served here,
                                                   relayed by the lab's
                                                   router/firewall)

    Module dependencies (install on the target box, or via the LCM's
    ResourceRepositoryWeb, before this configuration is applied):
        Install-Module xActiveDirectory -RequiredVersion 3.0.0
        Install-Module xDnsServer       -RequiredVersion 2.0.0
        Install-Module xDhcpServer      -RequiredVersion 2.0.0
        Install-Module xNetworking      -RequiredVersion 5.7.0

    The domain administrator password is never hard-coded here: it is
    supplied at compile/apply time via $SafeModeAdministratorCred /
    $DomainAdminCred, which callers should source from an environment
    variable or a secrets store — see scripts/apply-dsc.ps1, which reads
    $env:AD_SAFEMODE_PASSWORD and $env:AD_ADMIN_PASSWORD and fails loudly
    if either is unset, rather than falling back to a literal.
#>

Configuration DomainController
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string] $DomainName,

        [Parameter(Mandatory = $true)]
        [pscredential] $SafeModeAdministratorCred,

        [Parameter(Mandatory = $true)]
        [pscredential] $DomainAdminCred,

        [Parameter(Mandatory = $false)]
        [string] $DcIpAddress = "10.10.10.10",

        [Parameter(Mandatory = $false)]
        [string] $DnsForwarder = "1.1.1.1"
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName xActiveDirectory
    Import-DscResource -ModuleName xDnsServer
    Import-DscResource -ModuleName xDhcpServer
    Import-DscResource -ModuleName xNetworking

    Node "localhost"
    {
        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
            ActionAfterReboot  = "ContinueConfiguration"
            ConfigurationMode  = "ApplyOnly"
        }

        # --- Static IP on the lab-facing adapter -------------------------
        # Ethernet1 is the private_network adapter Vagrant attaches for
        # 10.10.10.0/24; Ethernet (the default NAT adapter) is left on DHCP
        # so box provisioning/package installs keep working.
        xIPAddress DcStaticIp
        {
            InterfaceAlias = "Ethernet 1"
            AddressFamily  = "IPv4"
            IPAddress      = $DcIpAddress
            SubnetMask     = 24
        }

        xDnsServerAddress DcOwnDns
        {
            InterfaceAlias = "Ethernet 1"
            AddressFamily  = "IPv4"
            Address        = "127.0.0.1"
            DependsOn      = "[xIPAddress]DcStaticIp"
        }

        # --- Windows roles/features ---------------------------------------
        WindowsFeature ADDSInstall
        {
            Ensure = "Present"
            Name   = "AD-Domain-Services"
        }

        WindowsFeature ADDSTools
        {
            Ensure    = "Present"
            Name      = "RSAT-ADDS-Tools"
            DependsOn = "[WindowsFeature]ADDSInstall"
        }

        WindowsFeature DnsServerInstall
        {
            Ensure = "Present"
            Name   = "DNS"
        }

        WindowsFeature DhcpServerInstall
        {
            Ensure = "Present"
            Name   = "DHCP"
        }

        # --- Promote to first DC in a new forest ---------------------------
        xADDomain FirstDC
        {
            DomainName                   = $DomainName
            SafemodeAdministratorPassword = $SafeModeAdministratorCred
            DomainAdministratorCredential = $DomainAdminCred
            DatabasePath                  = "C:\Windows\NTDS"
            LogPath                       = "C:\Windows\NTDS"
            SysvolPath                    = "C:\Windows\SYSVOL"
            DependsOn                     = @(
                "[WindowsFeature]ADDSInstall",
                "[xIPAddress]DcStaticIp"
            )
        }

        xWaitForADDomain WaitForDomain
        {
            DomainName           = $DomainName
            DomainUserCredential = $DomainAdminCred
            RetryCount           = 30
            RetryIntervalSec     = 30
            DependsOn            = "[xADDomain]FirstDC"
        }

        # --- DNS forwarder for external resolution -------------------------
        xDnsServerForwarder ExternalForwarder
        {
            IsSingleInstance = "Yes"
            IPAddresses      = @($DnsForwarder, "1.0.0.1")
            DependsOn        = "[xWaitForADDomain]WaitForDomain"
        }

        # --- DHCP scope for VLAN 20 (clients) -------------------------------
        # The scope itself lives on this DC; the lab's router/firewall is
        # configured (out of band, see topology.md) to relay DHCP broadcasts
        # from VLAN 20 back to this DC's VLAN 10 address.
        xDhcpServerScope ClientScope
        {
            Ensure        = "Present"
            ScopeId       = "10.10.20.0"
            IPStartRange  = "10.10.20.100"
            IPEndRange    = "10.10.20.200"
            SubnetMask    = "255.255.255.0"
            LeaseDuration = "08:00:00:00"
            State         = "Active"
            Name          = "VLAN20-Clients"
            AddressFamily = "IPv4"
            DependsOn     = "[WindowsFeature]DhcpServerInstall"
        }

        xDhcpServerOption ClientScopeOptions
        {
            ScopeID           = "10.10.20.0"
            DnsDomain         = $DomainName
            DnsServerIPAddress = @($DcIpAddress)
            Router            = @("10.10.20.1")
            AddressFamily     = "IPv4"
            DependsOn         = "[xDhcpServerScope]ClientScope"
        }

        # Authorize the DHCP server in AD so it's allowed to lease on a
        # domain network (a plain WindowsFeature install leaves an
        # unauthorized DHCP server that silently refuses to hand out leases).
        Script AuthorizeDhcp
        {
            GetScript  = {
                $auth = Get-DhcpServerInDC -ErrorAction SilentlyContinue |
                    Where-Object { $_.DnsName -eq $env:COMPUTERNAME + "." + $using:DomainName }
                return @{ Result = [string]($null -ne $auth) }
            }
            TestScript = {
                $fqdn = "$env:COMPUTERNAME.$using:DomainName"
                $auth = Get-DhcpServerInDC -ErrorAction SilentlyContinue
                return [bool]($auth | Where-Object { $_.DnsName -eq $fqdn })
            }
            SetScript  = {
                $fqdn = "$env:COMPUTERNAME.$using:DomainName"
                Add-DhcpServerInDC -DnsName $fqdn -ErrorAction Stop
            }
            DependsOn  = @(
                "[xDhcpServerScope]ClientScope",
                "[xWaitForADDomain]WaitForDomain"
            )
        }
    }
}
