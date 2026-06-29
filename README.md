# nat-manager-webui

Single-file PHP NAT management web UI for Proxmox VE servers with a public `/29` (or any) IP block.  
Everything — install, update, reinstall, uninstall, cleanup — is handled by one bash script.

![PHP 8.2](https://img.shields.io/badge/PHP-8.2-blue)
![Apache](https://img.shields.io/badge/Apache-2.4-red)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## Quick install

```bash
wget https://raw.githubusercontent.com/tnan/nat-manager-webui/main/nat-manager-webui-v1.0.0.sh
bash nat-manager-webui-v1.0.0.sh
```

The installer detects your bridge, public IP, gateway, and managed IP range automatically.  
After install, visit `http://your-server/nat-manager-webui/` and log in.

---

## What it does

| Tab | Features |
|-----|----------|
| **Port Forwarding** | Add/delete DNAT rules (TCP/UDP) · Live vs pending status · Sync rules from host iptables |
| **IPs & Gateways** | Manage public IP ranges · Per-IP mode: NAT (host-bound) or VM (released to Proxmox VM) · Live apply with streaming output |
| **Settings** | Change login credentials |

### IP assignment modes
- **NAT mode** (☑) — host binds the IP to the bridge with `ip addr add`, sends gratuitous ARP. Use for IPs you want to DNAT to internal VMs.
- **VM mode** (☐) — host releases the IP (`ip addr del`). Use for IPs assigned directly to a Proxmox VM's network interface on the public bridge.

---

## Requirements

- Proxmox VE (or any Debian/Ubuntu server with Apache + PHP)
- `apache2`, `php`, `libapache2-mod-php`, `iptables`, `sudo`, `iputils-arping`, `python3`
- The installer installs all dependencies automatically via `apt`

---

## Installer modes

```bash
bash nat-manager-webui-v1.0.0.sh            # interactive menu
bash nat-manager-webui-v1.0.0.sh install    # fresh install
bash nat-manager-webui-v1.0.0.sh update     # update app files, keep config
bash nat-manager-webui-v1.0.0.sh reinstall  # full reconfigure
bash nat-manager-webui-v1.0.0.sh uninstall  # interactive removal
bash nat-manager-webui-v1.0.0.sh cleanup    # remove ALL traces (all versions)
```

---

## File layout after install

```
/var/www/html/nat-manager-webui/
    index.php          ← single-file PHP app
    .htdata.json       ← config: auth + networks + rules (Apache-blocked, not downloadable)

/usr/local/bin/nat-mgr          ← privileged helper (sudo from PHP)
/etc/sudoers.d/nat-manager-webui
```

`.htdata.json` is protected by Apache's built-in `<FilesMatch "^\.ht">` rule — no custom Apache configuration needed.

---

## Network architecture

```
Internet → vmbr0 (public bridge, host IP + secondary IPs)
               ↓  iptables DNAT  (hairpin-safe: no -i restriction)
           vmbr1 (internal: 10.10.10.0/24)
               ↓
           VMs: 10.10.10.1, .2, .3 ...
```

Hairpin NAT is enabled via `POSTROUTING MASQUERADE` on the internal bridge, so VMs can reach public IPs that DNAT back to other internal VMs.

---

## Version convention

Releases are named `nat-manager-webui-vX.X.X.sh`.  
The version inside the script (`VERSION=`) and in the web UI (`APP_VERSION`) always match the filename.

---

## License

MIT — see [LICENSE](LICENSE)
