# Captive Portal
Bash script to automatically connect to a captive portal.

## Installation
```bash
cd
git clone https://github.com/JonasBouchard/captive-portal.git
cd captive-portal
chmod +x captive-portal.sh
```

## Usage
```bash
cd
./captive-portal/captive-portal.sh
```

The script performs a quick reachability test to `1.1.1.1` before attempting
portal detection. If the network is completely unreachable, it exits with a
clear message instead of timing out on DNS lookups.
