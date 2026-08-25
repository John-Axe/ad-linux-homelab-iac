# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# ad-linux-homelab-iac — Vagrantfile
#
# Mirrors the "VLAN 10 — Server/Infra" segment of the practice-lab topology
# documented in it-helpdesk-sysadmin-portfolio/network-lab/topology.md:
#   DC01    10.10.10.10   Windows Server 2019 — AD DS + DNS + DHCP
#   db01    10.10.10.20   Ubuntu 22.04 LTS    — stand-in "database" host
#   web02   10.10.10.21   Ubuntu 22.04 LTS    — stand-in "app/web" host
#   files01 10.10.10.22   Ubuntu 22.04 LTS    — stand-in "file server" host
#
# The router/firewall (pfSense, 192.168.0.1) and the VLAN 20 client segment
# from the reference topology are out of scope for this IaC repo — this repo
# provisions the server tier only, on a single VirtualBox host-only network
# that stands in for VLAN 10 (10.10.10.0/24). All four VMs get a private
# host-only adapter on that network in addition to Vagrant's default NAT
# adapter (used for internet access / box downloads / package installs).
#
# Domain: contoso.local (placeholder, matches the reference topology doc —
# not a real domain used anywhere else).

DOMAIN_NAME       = "contoso.local"
LAB_NETWORK       = "10.10.10.0/24"
DC_IP             = "10.10.10.10"
LINUX_HOSTS = {
  "db01"    => "10.10.10.20",
  "web02"   => "10.10.10.21",
  "files01" => "10.10.10.22",
}

Vagrant.configure("2") do |config|
  # ---------------------------------------------------------------------
  # DC01 — Windows Server domain controller
  # ---------------------------------------------------------------------
  config.vm.define "dc01" do |dc|
    # gusztavvargadr/windows-server is a well-known public Vagrant Cloud
    # box built from the Microsoft evaluation media (Server 2019/2022,
    # Desktop Experience). Pin the version explicitly in a real run;
    # left floating here so `vagrant box list` shows what's actually
    # cached rather than a version this repo can't verify against.
    dc.vm.box = "gusztavvargadr/windows-server"
    dc.vm.hostname = "dc01"

    dc.vm.network "private_network", ip: DC_IP, netmask: "255.255.255.0"

    dc.vm.provider "virtualbox" do |vb|
      vb.name = "adlab-dc01"
      vb.memory = 4096
      vb.cpus = 2
      # AD DS + DNS + DHCP roles are light at lab scale, but Windows
      # Server itself wants headroom to boot and run WinRM comfortably.
      vb.gui = false
    end

    # WinRM is the default Vagrant communicator for this box; give the
    # first boot (Sysprep + box init) plenty of time before giving up.
    dc.vm.boot_timeout = 600
    dc.vm.communicator = "winrm"

    # Bootstraps the DSC LCM (installs the required DSC resource modules)
    # and applies dsc/dc-configuration.ps1. Kept as a plain shell provisioner
    # (Vagrant's built-in `dsc` provisioner type is more brittle across
    # box/WinRM versions) invoking pwsh/powershell directly.
    dc.vm.provision "shell", path: "scripts/apply-dsc.ps1", privileged: true
  end

  # ---------------------------------------------------------------------
  # Linux server fleet — db01, web02, files01
  # ---------------------------------------------------------------------
  LINUX_HOSTS.each do |name, ip|
    config.vm.define name do |node|
      node.vm.box = "ubuntu/jammy64"
      node.vm.hostname = name

      node.vm.network "private_network", ip: ip, netmask: "255.255.255.0"

      node.vm.provider "virtualbox" do |vb|
        vb.name = "adlab-#{name}"
        vb.memory = 1024
        vb.cpus = 1
      end

      # Ansible runs once, after the last Linux node comes up, so the
      # inventory (all three hosts) is provisioned together in one pass
      # instead of three separate ansible-playbook invocations.
      if name == LINUX_HOSTS.keys.last
        node.vm.provision "ansible" do |ansible|
          ansible.playbook = "ansible/site.yml"
          ansible.inventory_path = "ansible/inventory.ini"
          ansible.limit = "all"
          ansible.extra_vars = {
            domain_name: DOMAIN_NAME,
            dc_ip: DC_IP,
          }
        end
      end
    end
  end
end
