#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
mode=${1:---serve}
adapter=${2:-Ethernet}
case $mode in --serve|--check|--self-test|--restore) ;; *) echo 'Usage: start-tftp-nand.sh [--serve|--check|--self-test|--restore] [Ethernet]'; exit 1 ;; esac
mkdir -p session
printf '\357\273\277' >session/run.ps1
cat >>session/run.ps1 <<'POWERSHELL'
param([string]$Mode, [string]$Adapter)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root 'tools\tftpd64.exe'
$image = Join-Path $root 'be7000-nand.bin'
$statePath = Join-Path $PSScriptRoot 'network-before.xml'
$rule = 'BE7000-NAND-TFTP-Temporary'
$server = $null
$added = $false
$state = $null
function Restore-Network {
    if (Test-Path -LiteralPath $statePath) {
        $saved = Import-Clixml -LiteralPath $statePath
        $nic = Get-NetAdapter | Where-Object ifIndex -eq $saved.Index
        if (!$nic -or $nic.InterfaceGuid -ne $saved.Guid) { throw 'Adapter identity changed; saved network state was retained.' }
    } else {
        $nic = Get-NetAdapter -Name $Adapter
    }
    foreach ($store in @('PersistentStore', 'ActiveStore')) {
        Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -PolicyStore $store -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.PrefixOrigin -eq 'Manual' -or [string]$_.PrefixOrigin -eq '1' } |
            ForEach-Object { Remove-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $_.IPAddress -PolicyStore $store -Confirm:$false }
        $current = Get-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -PolicyStore $store
        if ([string]$current.Dhcp -ne 'Enabled') {
            Set-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -Dhcp Enabled -PolicyStore $store
        }
    }
    Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 |
        Set-DnsClientServerAddress -ResetServerAddresses
    Remove-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
    Write-Host 'Automatic IPv4 and DNS enabled. Waiting for the router DHCP server may take a few seconds.'
}
function Set-TftpAddress {
    param([int]$Index, [string]$Address)
    Set-NetIPInterface -InterfaceIndex $Index -AddressFamily IPv4 -Dhcp Disabled -PolicyStore ActiveStore
    Get-NetIPAddress -InterfaceIndex $Index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -ne $Address | Remove-NetIPAddress -Confirm:$false
    $existing = Get-NetIPAddress -InterfaceIndex $Index -IPAddress $Address -ErrorAction SilentlyContinue
    if (!$existing) {
        try {
            New-NetIPAddress -InterfaceIndex $Index -IPAddress $Address -PrefixLength 24 -SkipAsSource $false -PolicyStore ActiveStore | Out-Null
        } catch {
            $existing = Get-NetIPAddress -InterfaceIndex $Index -IPAddress $Address -ErrorAction SilentlyContinue
            if (!$existing) { throw }
        }
    }
    Set-NetIPAddress -InterfaceIndex $Index -IPAddress $Address -PrefixLength 24 -SkipAsSource $false -PolicyStore ActiveStore
}
if ($Mode -eq 'restore') { Restore-Network; exit }
foreach ($file in @($exe, $image)) { if (!(Test-Path -LiteralPath $file)) { throw "Missing file: $file" } }
$stream = [IO.File]::OpenRead($image)
try { $magic = New-Object byte[] 4; [void]$stream.Read($magic, 0, 4) } finally { $stream.Dispose() }
if ([BitConverter]::ToString($magic) -ne 'D0-0D-FE-ED') { throw 'The image is not a FIT. Refusing to serve it.' }
if ((Get-Item -LiteralPath $image).Length -ge 0x4000000) { throw 'The FIT exceeds the reserved TFTP receive area.' }
if ($Mode -eq 'serve' -and (Get-Process tftpd64,tftpd32,MIWIFIRepairTool.x86 -ErrorAction SilentlyContinue)) { throw 'Close the other TFTP/MIWIFI repair server first.' }
if ($Mode -eq 'check') {
    Get-NetAdapter -Name $Adapter | Format-Table Name,Status,InterfaceDescription
    Write-Host "FIT: $image ($((Get-Item -LiteralPath $image).Length) bytes)"
    Write-Host 'Preflight OK. Router prerequisite: autostart=yes. This script does not change U-Boot environment.'
    exit
}
$selfTest = $Mode -eq 'self-test'
$ip = if ($selfTest) { '127.0.0.1' } else { '192.168.31.100' }
$port = if ($selfTest) { 1069 } else { 69 }
$services = if ($selfTest) { 1 } else { 5 }
$log = Join-Path $PSScriptRoot $(if ($selfTest) { 'self-test.log' } else { 'tftp.log' })
$ini = Join-Path $PSScriptRoot 'tftpd32.ini'
@"
[TFTPD32]
BaseDirectory=$root
TftpPort=$port
Services=$services
LocalIP=$ip
DHCP LocalIP=$ip
SecurityLevel=3
Hide=1
Negociate=1
PXECompatibility=0
Timeout=3
MaxRetransmit=6
WinSize=0
UnixStrings=0
VirtualRoot=0
MD5=0
TftpLogFile=$log
PersistantLeases=0
DHCP Ping=0
DHCP Double Answer=0
UnicastBOOTP=0
Enable IPv4=1
Enable IPv6=0
Donot verify firewall=1
Max Simultaneous Transfers=4
UseEventLog=0
[DHCP]
IP_Pool=192.168.31.1
PoolSize=1
BootFile=be7000-nand.bin
Mask=255.255.255.0
Gateway=0.0.0.0
DNS=0.0.0.0
DNS2=0.0.0.0
WINS=0.0.0.0
Lease (minutes)=5
AddOptionNumber1=66
AddOptionValue1=$ip
Lease_NumLeases=0
"@ | Set-Content -LiteralPath $ini -Encoding ASCII
try {
    if (!$selfTest) {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run start-tftp-nand.cmd as administrator.' }
        if (Test-Path -LiteralPath $statePath) {
            Write-Host 'Restoring the unfinished network session before starting TFTP.'
            Restore-Network
        }
        $nic = Get-NetAdapter -Name $Adapter
        if (Get-NetIPAddress -IPAddress $ip -ErrorAction SilentlyContinue | Where-Object InterfaceIndex -ne $nic.ifIndex) { throw "$ip is configured on another adapter." }
        if (Get-NetUDPEndpoint -LocalPort 67,69 -ErrorAction SilentlyContinue) { throw 'UDP 67 or 69 is already in use.' }
        $state = [pscustomobject]@{ Index=$nic.ifIndex; Guid=$nic.InterfaceGuid }
        $state | Export-Clixml -LiteralPath $statePath
        $added = $true
        Set-TftpAddress -Index $nic.ifIndex -Address $ip
        for ($attempt=0; $attempt -lt 60; $attempt++) {
            $address = Get-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $ip -ErrorAction SilentlyContinue
            if ($address.AddressState -eq 'Preferred') { break }
            if ($address.AddressState -eq 'Duplicate') { throw "$ip is already used by another device." }
            Start-Sleep -Milliseconds 250
        }
        if ($address.AddressState -ne 'Preferred') { throw "$ip did not become ready on $Adapter. Check the Ethernet connection." }
        Remove-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name $rule -DisplayName 'BE7000 temporary TFTP and DHCP' -Direction Inbound -Action Allow -Program $exe -Protocol UDP -InterfaceAlias $Adapter -Profile Any | Out-Null
    }
    $server = Start-Process -FilePath $exe -ArgumentList @('-i', ('"' + $ini + '"')) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru
    for ($attempt=0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 250
        if ($server.HasExited) { throw 'Tftpd64 stopped during startup.' }
        $listeners = @(Get-NetUDPEndpoint -OwningProcess $server.Id -ErrorAction SilentlyContinue)
        if (($listeners.LocalPort -contains $port) -and ($selfTest -or ($listeners.LocalPort -contains 67))) { break }
    }
    if (!($listeners.LocalPort -contains $port) -or (!$selfTest -and !($listeners.LocalPort -contains 67))) { throw 'TFTP/DHCP sockets did not open.' }
    if ($selfTest) {
        $client = New-Object Net.Sockets.UdpClient
        $client.Client.ReceiveTimeout = 5000
        try {
            $request = [byte[]](0,1) + [Text.Encoding]::ASCII.GetBytes("be7000-nand.bin`0octet`0")
            [void]$client.Send($request, $request.Length, $ip, $port)
            $remote = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            $total = 0L
            $block = 1
            do {
                $packet = $client.Receive([ref]$remote)
                if ($packet.Length -lt 4 -or $packet[1] -ne 3) { throw 'Expected a TFTP DATA packet.' }
                $number = ([int]$packet[2] -shl 8) -bor $packet[3]
                if ($number -ne ($block -band 65535)) { throw "Unexpected TFTP block: $number" }
                if ($block -eq 1 -and [BitConverter]::ToString($packet,4,4) -ne 'D0-0D-FE-ED') { throw 'Wrong TFTP payload.' }
                $total += $packet.Length - 4
                $ack = [byte[]](0,4,$packet[2],$packet[3])
                [void]$client.Send($ack, 4, $remote)
                $block++
            } while ($packet.Length -eq 516)
            if ($total -ne (Get-Item -LiteralPath $image).Length) { throw 'Incomplete TFTP transfer.' }
            Write-Host "Local TFTP transfer passed: $total bytes, $($block-1) blocks."
        } finally { $client.Dispose() }
    } else {
        Write-Host 'DHCP + read-only TFTP ready on 192.168.31.100.'
        Write-Host 'Keep the USB drive connected. Power on the router while holding Reset.'
        Write-Host 'Release Reset when recovery starts. U-Boot must already have autostart=yes.'
        Write-Host "Transfer log: $log"
        Write-Host 'Press Enter after the transfer/boot attempt to stop the server and enable automatic IPv4 and DNS on the PC.'
        [void](Read-Host)
    }
} finally {
    if ($server -and !$server.HasExited) { Stop-Process -Id $server.Id -ErrorAction Continue }
    if ($added) { Restore-Network }
}
POWERSHELL
cleanup() {
    if [[ $mode == --serve && -f session/network-before.xml ]]; then
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$PWD/session/run.ps1")" -Mode restore -Adapter "$adapter"
    fi
}
trap cleanup EXIT
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$PWD/session/run.ps1")" -Mode "${mode#--}" -Adapter "$adapter"
