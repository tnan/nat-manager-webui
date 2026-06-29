# Changelog

All notable changes to nat-manager-webui are documented here.

---

## [1.0.0] — 2026-06-28 — First stable release

### What it is
Single-file PHP NAT management web UI for Proxmox VE servers with a public IP block.  
Everything ships in one bash installer script (`nat-manager-webui-v1.0.0.sh`).

### Features
- **Port forwarding** — add/delete DNAT rules (TCP/UDP), live vs pending status badges
- **IP assignment** — per-IP toggle: NAT mode (host claims IP, sends ARP) or VM mode (host releases IP to Proxmox VM directly on bridge)
- **Live apply** — streaming SSE output shows `[BIND]`, `[RULE]`, `[ARP]`, `[RELEASE]` in real time
- **Sync from host** — import rules already live in iptables into config
- **IPs & Gateways tab** — manage public IP ranges, add multiple gateways/bridges
- **Settings tab** — change login credentials (bcrypt, written directly to data file)
- **Dark/light mode** — persisted via `localStorage`, applied before first paint (no flash)
- **Auto-populated config** — bridge, gateway, prefix, and all managed IPs are detected and written to `.htdata.json` at install time; nothing to configure manually after first login
- **Version badge** — `v1.0.0` shown in authenticated top bar

### Security
- `.htdata.json` data file lives in the webroot but is blocked by Apache's built-in `<FilesMatch "^\.ht">` rule (`/etc/apache2/conf-enabled/security.conf`) — no custom Apache config needed
- Bcrypt passwords, CSRF tokens on all POST, rate limiting (5 fails → 5 min lockout)
- Session timeout (1 hour), `session_regenerate_id` on login
- Security headers: `X-Frame-Options: DENY`, `Content-Security-Policy`, `X-Content-Type-Options`, `Referrer-Policy`
- `www-data` sudoers rule limited to `/usr/local/bin/nat-mgr` only

### Installer modes (`bash nat-manager-webui-v1.0.0.sh`)
| Mode | Description |
|------|-------------|
| `install` | Fresh interactive install — detects bridge, IPs, gateway automatically |
| `update` | Re-deploy `index.php` + `nat-mgr`, preserve `.htdata.json` |
| `reinstall` | Full reconfigure — keep or replace existing config |
| `uninstall` | Interactive removal by category |
| `cleanup` | One-confirm removal of ALL traces from ALL historical versions |

### Architecture
```
/var/www/html/nat-manager-webui/
    index.php          ← single-file PHP app (all functions at top, no ?> in comments)
    .htdata.json       ← plain JSON config (auth + networks + rules), Apache-blocked

/usr/local/bin/nat-mgr ← privileged bash helper (invoked via sudo from PHP)
/etc/sudoers.d/nat-manager-webui
```

### Network model
```
Internet → vmbr0 (public bridge)
               ↓  iptables DNAT (no -i restriction — hairpin NAT safe)
           vmbr1 (internal bridge, 10.10.10.0/24)
               ↓
           VMs: 10.10.10.1, .2, .3 ...
```
`POSTROUTING MASQUERADE` on the internal bridge enables hairpin NAT (VMs can reach public IPs that DNAT back to other VMs).

### Key implementation notes
- All PHP functions defined at the **very top of `index.php`** (before any `?>` output) — PHP's `//` comments terminate at `?>` even mid-line, so `?>` must never appear in comments
- Data writing uses Python with **environment variables** (not bash JSON quoting) — eliminates all shell quoting issues with IP addresses, bcrypt hashes, and JSON
- `nat-mgr` IP sync loop uses `read -r BR GW PFX IP MODE` (5 fields) matching Python's `bridge|gw|pfx|ip|mode` output format
- `nat-mgr` python blocks pass `$DATA` as `sys.argv[1]` (outside the single-quoted heredoc) so the path is expanded by bash before Python runs

---

*Version filename convention: `nat-manager-webui-vX.X.X.sh` — always matches the `VERSION=` constant inside the script and the `APP_VERSION` constant in `index.php`.*
