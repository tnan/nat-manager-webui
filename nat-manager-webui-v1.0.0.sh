#!/bin/bash
VERSION="1.0.0"
# =============================================================================
# nat-manager-webui.sh — all-in-one NAT Manager WebUI management script
#
#   bash nat-manager-webui.sh install    — fresh install (interactive)
#   bash nat-manager-webui.sh update     — update app + nat-mgr, keep config
#   bash nat-manager-webui.sh reinstall  — full re-setup, preserve data + creds
#   bash nat-manager-webui.sh uninstall  — remove everything
# =============================================================================
set -u

# ── Paths ─────────────────────────────────────────────────────────────────────
WEBROOT="/var/www/html/nat-manager-webui"
INDEX="${WEBROOT}/index.php"
DATA="${WEBROOT}/.htdata.json"
NATMGR="/usr/local/bin/nat-mgr"
SUDOERS="/etc/sudoers.d/nat-manager-webui"
RULES="/etc/iptables/rules.v4"
UNIT="/etc/systemd/system/nat-manager-webui.service"
SYSCTL="/etc/sysctl.d/99-nat-manager.conf"
LOG_NAT="/var/log/nat-manager.log"

# ── Colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; BD='\033[1m'; N='\033[0m'
ok()   { echo -e "  ${G}[✓]${N} $1"; }
info() { echo -e "  ${B}[→]${N} $1"; }
warn() { echo -e "  ${Y}[!]${N} $1"; }
hdr()  { echo -e "\n${BD}${C}─── $1 ───${N}"; }
die()  { echo -e "\n  ${R}[✗] $1${N}\n"; exit 1; }

[ "$(id -u)" = "0" ] || die "Run as root"

# ── Shared helpers ─────────────────────────────────────────────────────────────
present() { [ -e "$1" ] || [ -L "$1" ]; }
rmf()     { present "$1" && rm -f  "$1" && ok  "Removed $1" || true; }
rmrf()    { present "$1" && rm -rf "$1" && ok  "Removed $1" || true; }
ask()     { if [ "${YES:-0}" = "1" ]; then echo y; return; fi
            local a; read -rp "  $1 [y/N]: " a; echo "${a:-n}"; }
ip_to_json() { local a=""; for ip in $1; do [ -n "$a" ] && a+=","; a+="\"$ip\""; done; echo "$a"; }

# ── write_index: write index.php with __ADMIN_USER__ / __PASS_HASH__ placeholders ──
write_index() {
cat > "$INDEX" << 'NMWEBUI_INDEX_PHP'
<?php
// nat-manager-webui — single-file NAT manager
// .htdata.json is in the same folder as index.php.
// Apache blocks ALL .ht* files by default (built-in FilesMatch rule in Debian/Ubuntu).
// No extra Apache config needed. PHP reads it normally via file_get_contents().
const APP_VERSION     = '1.0.0';
const DATA_FILE       = __DIR__ . '/.htdata.json';
const NAT_MGR         = '/usr/local/bin/nat-mgr';
const SESSION_TIMEOUT = 3600;

// =============================================================================
// ALL FUNCTION DEFINITIONS — must be at top level before any [?]> switching
// PHP hoists top-level function declarations only; conditional/inline [?]> blocks
// can break hoisting for functions defined later in the file.
// =============================================================================

function load_data(): array {
    if (!is_file(DATA_FILE)) return [];
    $raw = file_get_contents(DATA_FILE);
    if ($raw === false || $raw === '') return [];
    $d = json_decode(trim($raw), true);
    return is_array($d) ? $d : [];
}

function save_data(array $d): void {
    file_put_contents(DATA_FILE, json_encode($d, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
}

function e(string $s): string {
    return htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function run_nat(string ...$args): string {
    $cmd = 'sudo ' . NAT_MGR;
    foreach ($args as $a) $cmd .= ' ' . escapeshellarg($a);
    return shell_exec($cmd . ' 2>&1') ?? '';
}

function csrf(): string {
    if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(24));
    return $_SESSION['csrf'];
}

function csrf_ok(): bool {
    $t = $_POST['csrf'] ?? '';
    return $t !== '' && hash_equals($_SESSION['csrf'] ?? '', $t);
}

function cf(): string {
    return '<input type="hidden" name="csrf" value="' . csrf() . '">';
}

function rl_file(): string {
    return '/tmp/.nmrl_' . substr(hash('sha256', $_SERVER['REMOTE_ADDR'] ?? 'x'), 0, 16);
}

function rl_wait(): int {
    $f = rl_file();
    if (!is_file($f)) return 0;
    $d = json_decode(file_get_contents($f), true) ?? [];
    return (($d['lock'] ?? 0) > time()) ? ($d['lock'] - time()) : 0;
}

function rl_fail(): void {
    $f = rl_file();
    $d = is_file($f) ? (json_decode(file_get_contents($f), true) ?? []) : [];
    $d['fails'] = ($d['fails'] ?? 0) + 1;
    if ($d['fails'] >= 5) { $d['lock'] = time() + 300; $d['fails'] = 0; }
    file_put_contents($f, json_encode($d));
}

function rl_reset(): void { @unlink(rl_file()); }

// show_setup_error: pure echo, no [?]> — shown when data.php is missing/invalid
function show_setup_error(string $reason): void {
    http_response_code(503);
    $r   = e($reason);
    $f   = e(DATA_FILE);
    $css = ':root{--bg:#f5f5f2;--card:#fff;--b:#e0e0d8;--t:#111;--m:#777;--ac:#2563eb;'
         . '--er-bg:#fef2f2;--er-c:#b91c1c;--er-b:#fecaca;}'
         . '[data-theme=dark]{--bg:#0d0d0d;--card:rgba(255,255,255,.04);--b:rgba(255,255,255,.08);'
         . '--t:#f0f0f0;--m:#666;--er-bg:rgba(239,68,68,.08);--er-c:#f87171;--er-b:rgba(239,68,68,.2);}'
         . '*{box-sizing:border-box;margin:0;padding:0}'
         . 'body{font-family:system-ui,sans-serif;background:var(--bg);color:var(--t);'
         . 'display:flex;align-items:center;justify-content:center;min-height:100vh;padding:20px}'
         . '.w{width:100%;max-width:480px}'
         . '.ic{width:46px;height:46px;background:linear-gradient(135deg,#dc2626,#9f1239);'
         . 'border-radius:11px;display:flex;align-items:center;justify-content:center;'
         . 'margin:0 auto 14px;font-size:22px}'
         . 'h1{font-size:20px;text-align:center;margin-bottom:4px}'
         . 'p.sub{font-size:12px;color:var(--m);text-align:center;margin-bottom:20px;font-family:monospace}'
         . '.card{background:var(--card);border:1px solid var(--b);border-radius:12px;padding:24px}'
         . '.er{background:var(--er-bg);border:1px solid var(--er-b);color:var(--er-c);'
         . 'padding:12px 14px;border-radius:8px;font-size:13px;margin-bottom:18px}'
         . '.er strong{display:block;margin-bottom:4px}'
         . 'h3{font-size:12px;font-weight:600;color:var(--m);text-transform:uppercase;'
         . 'letter-spacing:.5px;margin:0 0 10px}'
         . '.step{display:flex;gap:10px;margin-bottom:10px;font-size:13px}'
         . '.num{width:22px;height:22px;min-width:22px;border-radius:50%;background:var(--ac);'
         . 'color:#fff;font-size:11px;font-weight:700;display:flex;align-items:center;justify-content:center}'
         . 'pre{background:rgba(0,0,0,.06);border-radius:6px;padding:10px 12px;font-size:12px;'
         . 'font-family:monospace;margin:8px 0;color:var(--t)}'
         . 'code{background:rgba(0,0,0,.07);border-radius:4px;padding:1px 5px;font-size:12px;font-family:monospace}'
         . '.tog{position:fixed;top:12px;right:12px;background:none;border:1px solid var(--b);'
         . 'border-radius:6px;padding:4px 8px;font-size:11px;color:var(--m);cursor:pointer}';
    $thjs = "document.documentElement.setAttribute('data-theme',"
           . "localStorage.getItem('nmTheme')||'light')";
    $tgjs = "var t=document.documentElement.getAttribute('data-theme')==='dark'?'light':'dark';"
           . "document.documentElement.setAttribute('data-theme',t);"
           . "localStorage.setItem('nmTheme',t)";
    echo '<!DOCTYPE html><html lang="en"><head>'
       . '<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
       . '<title>NAT Manager &#8212; Setup Required</title>'
       . '<script>(function(){' . $thjs . '})();</script>'
       . '<style>' . $css . '</style></head><body>'
       . '<div class="w">'
       . '<div class="ic">&#9888;</div>'
       . '<h1>Setup Required</h1>'
       . '<p class="sub">NAT Manager needs to be configured.</p>'
       . '<div class="card">'
       . '<div class="er"><strong>Problem:</strong> ' . $r . '</div>'
       . '<h3>How to fix</h3>'
       . '<div class="step"><div class="num">1</div>'
       . '<div>Copy <code>nat-manager-webui.sh</code> to your server and run as root:</div></div>'
       . '<pre>bash nat-manager-webui.sh</pre>'
       . '<div class="step"><div class="num">2</div>'
       . '<div>Choose <strong>Install</strong> (fresh) or <strong>Reinstall</strong> (recover).</div></div>'
       . '<div class="step"><div class="num">3</div>'
       . '<div>Reload this page after the script completes.</div></div>'
       . '<div style="margin-top:16px;font-size:11px;color:var(--m)">Config file: <code>' . $f . '</code></div>'
       . '</div></div>'
       . '<button class="tog" onclick="' . $tgjs . '">&#9728;/&#9790;</button>'
       . '</body></html>';
}

// =============================================================================
// RUNTIME — session, headers, checks, handlers, output
// All functions above are already registered; no hoisting issues below.
// =============================================================================

$secure = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off');
session_set_cookie_params(['lifetime'=>0,'path'=>'/','httponly'=>true,'samesite'=>'Lax','secure'=>$secure]);
session_name('natmgr');
session_start();

header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('X-Permitted-Cross-Domain-Policies: none');
header("Permissions-Policy: camera=(), microphone=(), geolocation=()");
header("Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'none'");

// ── .htdata.json integrity check ─────────────────────────────────────────────
(function() {
    if (!is_file(DATA_FILE)) {
        show_setup_error('Config file not found: ' . DATA_FILE . ' — run the installer.');
        exit;
    }
    $raw = file_get_contents(DATA_FILE);
    if ($raw === false || trim($raw) === '') {
        show_setup_error('Config file is empty or unreadable: ' . DATA_FILE);
        exit;
    }
    // Plain JSON — no header stripping needed for .htdata.json
    $parsed  = json_decode(trim($raw), true);
    if (!is_array($parsed)) {
        show_setup_error('Config file contains invalid JSON (' . json_last_error_msg() . '). Run reinstall.');
        exit;
    }
    if (empty($parsed['auth']['user']) || empty($parsed['auth']['hash'])) {
        show_setup_error('Credentials missing in config file. Run reinstall to reconfigure.');
        exit;
    }
    if (!isset($parsed['networks']) || !isset($parsed['rules'])) {
        show_setup_error('Config file is missing required keys. Run reinstall to rebuild.');
        exit;
    }
})();

// ── Auth ──────────────────────────────────────────────────────────────────────
$_d          = load_data();
$ADMIN_USER  = $_d['auth']['user'] ?? '';
$PASS_HASH   = $_d['auth']['hash'] ?? '';

// ── Streaming apply endpoint ──────────────────────────────────────────────────
if (!empty($_SESSION['ok']) && ($_GET['stream'] ?? '') === 'apply') {
    if (!csrf_ok()) { echo "data: \"CSRF error\"\n\ndata: \"__done__\"\n\n"; exit; }
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $d       = load_data();
        $all_ips = array_merge(...array_map(fn($n) => $n['ips'] ?? [], $d['networks'] ?? []) ?: [[]]);
        $nat_ips = array_values(array_filter(
            $_POST['nat_ips'] ?? [],
            fn($ip) => filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)
        ));
        $d['released'] = array_values(array_filter($all_ips, fn($ip) => !in_array($ip, $nat_ips, true)));
        save_data($d);
    }
    session_write_close();
    @ini_set('output_buffering', 'off');
    @ini_set('zlib.output_compression', 0);
    @apache_setenv('no-gzip', 1);
    while (ob_get_level()) @ob_end_flush();
    header('Content-Type: text/event-stream');
    header('Cache-Control: no-cache');
    header('X-Accel-Buffering: no');
    $proc = popen('sudo ' . NAT_MGR . ' apply 2>&1', 'r');
    while ($proc && !feof($proc)) {
        $line = fgets($proc, 4096);
        if ($line !== false && trim($line) !== '') {
            echo 'data: ' . json_encode(trim($line)) . "\n\n";
            flush();
        }
    }
    if ($proc) pclose($proc);
    echo "data: \"__done__\"\n\n";
    flush();
    exit;
}

// ── Logout ────────────────────────────────────────────────────────────────────
if (isset($_GET['logout'])) { $_SESSION = []; session_destroy(); header('Location: ?'); exit; }

// ── Session timeout ───────────────────────────────────────────────────────────
if (!empty($_SESSION['ok'])) {
    if (!empty($_SESSION['expires']) && $_SESSION['expires'] < time()) {
        $_SESSION = []; session_destroy(); session_start();
    } else {
        $_SESSION['expires'] = time() + SESSION_TIMEOUT;
    }
}

// ── Login handler ─────────────────────────────────────────────────────────────
$login_notice = isset($_GET['updated']) ? 'Credentials updated. Please sign in with your new login.' : '';
$login_err    = '';
if (isset($_POST['_login'])) {
    if (!csrf_ok())                    $login_err = 'Session expired — try again.';
    elseif (($w = rl_wait()) > 0)      $login_err = 'Too many attempts. Try again in ' . ceil($w / 60) . ' min.';
    elseif (hash_equals($ADMIN_USER, $_POST['user'] ?? '') && password_verify($_POST['pass'] ?? '', $PASS_HASH)) {
        session_regenerate_id(true);
        $_SESSION['ok']      = 1;
        $_SESSION['expires'] = time() + SESSION_TIMEOUT;
        rl_reset();
        header('Location: ?');
        exit;
    } else { rl_fail(); $login_err = 'Invalid credentials.'; }
}

// ── Login page (pure echo — no [?]> switching) ──────────────────────────────────
if (empty($_SESSION['ok'])) {
    $thjs2 = "document.documentElement.setAttribute('data-theme',localStorage.getItem('nmTheme')||'light')";
    $tgjs2 = "var t=document.documentElement.getAttribute('data-theme')==='dark'?'light':'dark';"
            . "document.documentElement.setAttribute('data-theme',t);"
            . "localStorage.setItem('nmTheme',t)";
    $css2  = ':root{--bg:#f5f5f2;--card:#fff;--b:#e0e0d8;--t:#111;--m:#777;--ac:#2563eb;--ac2:#7c3aed;'
           . '--ib:#fafaf8;--ib2:#d4d4cc;--er-bg:#fef2f2;--er-c:#b91c1c;--er-b:#fecaca;'
           . '--ok-bg:#f0fdf4;--ok-c:#15803d;--ok-b:#bbf7d0;}'
           . '[data-theme=dark]{--bg:#0d0d0d;--card:rgba(255,255,255,.04);--b:rgba(255,255,255,.08);'
           . '--t:#f0f0f0;--m:#666;--ib:rgba(255,255,255,.05);--ib2:rgba(255,255,255,.1);'
           . '--er-bg:rgba(239,68,68,.1);--er-c:#f87171;--er-b:rgba(239,68,68,.25);'
           . '--ok-bg:rgba(34,197,94,.08);--ok-c:#4ade80;--ok-b:rgba(34,197,94,.2);}'
           . '*{box-sizing:border-box;margin:0;padding:0}html,body{height:100%}'
           . 'body{font-family:system-ui,sans-serif;background:var(--bg);color:var(--t);'
           . 'display:flex;flex-direction:column;align-items:center;justify-content:center;'
           . 'padding:20px;transition:background .2s}'
           . '.w{width:100%;max-width:340px}.logo{text-align:center;margin-bottom:22px}'
           . '.ic2{width:46px;height:46px;background:linear-gradient(135deg,var(--ac),var(--ac2));'
           . 'border-radius:11px;display:flex;align-items:center;justify-content:center;'
           . 'margin:0 auto 10px;font-size:11px;font-weight:700;font-family:monospace;color:#fff}'
           . 'h1{font-size:18px}h1+p{font-size:11px;color:var(--m);margin-top:2px;font-family:monospace}'
           . '.card{background:var(--card);border:1px solid var(--b);border-radius:12px;padding:24px}'
           . 'label{display:block;font-size:10px;font-weight:600;color:var(--m);margin-bottom:5px;'
           . 'text-transform:uppercase;letter-spacing:.5px}'
           . 'input[type=text],input[type=password]{width:100%;padding:10px 12px;margin-bottom:14px;'
           . 'background:var(--ib);border:1px solid var(--ib2);border-radius:7px;color:var(--t);'
           . 'font-family:monospace;font-size:13px;outline:none;transition:border-color .15s}'
           . 'input:focus{border-color:var(--ac)}'
           . 'button.sub{width:100%;padding:11px;background:linear-gradient(135deg,var(--ac),var(--ac2));'
           . 'border:none;border-radius:7px;color:#fff;font-size:14px;font-weight:600;cursor:pointer}'
           . 'button.sub:hover{opacity:.9}'
           . '.er2{background:var(--er-bg);border:1px solid var(--er-b);color:var(--er-c);'
           . 'padding:9px 12px;border-radius:7px;font-size:12px;margin-bottom:13px}'
           . '.nt{background:var(--ok-bg);border:1px solid var(--ok-b);color:var(--ok-c);'
           . 'padding:9px 12px;border-radius:7px;font-size:12px;margin-bottom:13px}'
           . '.foot{text-align:center;margin-top:14px;display:flex;align-items:center;'
           . 'justify-content:center;gap:8px}'
           . '.foot span{font-size:10px;color:var(--m);font-family:monospace}'
           . '.tog2{background:none;border:1px solid var(--b);border-radius:6px;padding:4px 8px;'
           . 'font-size:11px;color:var(--m);cursor:pointer}.tog2:hover{border-color:var(--ac);color:var(--ac)}';
    $ntHtml = $login_notice ? '<div class="nt">' . e($login_notice) . '</div>' : '';
    $erHtml = $login_err    ? '<div class="er2">' . e($login_err) . '</div>'   : '';
    echo '<!DOCTYPE html><html lang="en"><head>'
       . '<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
       . '<title>NAT Manager &#8212; Login</title>'
       . '<script>(function(){' . $thjs2 . '})();</script>'
       . '<style>' . $css2 . '</style></head><body>'
       . '<div class="w">'
       . '<div class="logo">'
       . '<div class="ic2">NAT</div>'
       . '<h1>NAT Manager</h1><p>Port forwarding &amp; IP control</p>'
       . '</div>'
       . '<div class="card">'
       . $ntHtml . $erHtml
       . '<form method="POST" action="?">' . cf() . '<input type="hidden" name="_login" value="1">'
       . '<label>Username</label>'
       . '<input type="text" name="user" autocomplete="username" autofocus>'
       . '<label>Password</label>'
       . '<input type="password" name="pass" autocomplete="current-password">'
       . '<button type="submit" class="sub">Sign In</button>'
       . '</form></div>'
       . '<div class="foot"><span>NAT Manager</span>'
       . '<button class="tog2" onclick="' . $tgjs2 . '">&#9728; / &#9790;</button>'
       . '</div></div>'
       . '</body></html>';
    exit;
}

// ── CSRF on all POST ──────────────────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] === 'POST' && !csrf_ok()) {
    http_response_code(403);
    exit('CSRF failed. <a href="?">Reload</a>');
}

// ── Load data + state ─────────────────────────────────────────────────────────
$data         = load_data();
$nets         = $data['networks']   ?? [];
$host_ip      = $data['host_ip']    ?? '';
$released_ips = $data['released']   ?? [];
$stored_rules = $data['rules']      ?? [];
$managed_ips  = array_merge(...array_map(fn($n) => $n['ips'] ?? [], $nets) ?: [[]]);
$ip_br        = [];
foreach ($nets as $n) foreach ($n['ips'] ?? [] as $ip) $ip_br[$ip] = $n['bridge'];
$msg = ''; $mt = '';

// ── Actions ───────────────────────────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $act = $_POST['action'] ?? '';

    if ($act === 'add_rule') {
        $pi = trim($_POST['pub_ip']   ?? ''); $pp = (int)($_POST['pub_port'] ?? 0);
        $ii = trim($_POST['int_ip']   ?? ''); $ip = (int)($_POST['int_port'] ?? 0);
        $pr = ($_POST['proto'] ?? 'tcp') === 'udp' ? 'udp' : 'tcp';
        if (!filter_var($pi, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)
         || !filter_var($ii, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
            $msg = 'Invalid IP address.'; $mt = 'er';
        } elseif ($managed_ips && !in_array($pi, $managed_ips, true)) {
            $msg = 'Public IP not in managed list.'; $mt = 'er';
        } elseif ($host_ip && $pi === $host_ip) {
            $msg = 'Refusing to DNAT the host IP.'; $mt = 'er';
        } elseif ($pp < 1 || $pp > 65535 || $ip < 1 || $ip > 65535) {
            $msg = 'Port must be 1–65535.'; $mt = 'er';
        } else {
            $dup = false;
            foreach ($data['rules'] ?? [] as $r)
                if ($r['proto'] === $pr && $r['pub_ip'] === $pi && (int)$r['pub_port'] === $pp) { $dup = true; break; }
            if ($dup) { $msg = "Rule $pi:$pp ($pr) already exists."; $mt = 'er'; }
            else {
                $data['rules'][] = ['proto'=>$pr,'pub_ip'=>$pi,'pub_port'=>$pp,'int_ip'=>$ii,'int_port'=>$ip];
                save_data($data);
                $out = run_nat('apply');
                $err = (bool)preg_match('/error|fail/i', $out);
                $msg = $err ? 'Saved but apply had errors: ' . trim($out) : "Added: $pi:$pp → $ii:$ip ($pr)";
                $mt  = $err ? 'er' : 'ok';
            }
        }
    } elseif ($act === 'del_rule') {
        $idx = (int)($_POST['rule_idx'] ?? -1);
        if (isset($data['rules'][$idx])) {
            array_splice($data['rules'], $idx, 1);
            save_data($data);
            run_nat('apply');
            $msg = 'Rule deleted and applied.'; $mt = 'ok';
        }
    } elseif ($act === 'sync_from_host') {
        $raw2     = run_nat('sync-host');
        $imported = json_decode($raw2, true);
        if (!is_array($imported)) { $msg = 'Failed to read host state: ' . trim($raw2); $mt = 'er'; }
        else {
            $hkeys = [];
            foreach ($data['rules'] ?? [] as $r) $hkeys[] = $r['proto'] . '|' . $r['pub_ip'] . '|' . $r['pub_port'];
            $added = 0;
            foreach ($imported['rules'] ?? [] as $r) {
                $k = $r['proto'] . '|' . $r['pub_ip'] . '|' . $r['pub_port'];
                if (!in_array($k, $hkeys, true)) { $data['rules'][] = $r; $added++; }
            }
            save_data($data);
            $msg = "Synced: $added new rule(s) imported. " . count($imported['rules'] ?? []) . " found on host.";
            $mt  = 'ok';
        }
    } elseif ($act === 'sync_mode') {
        $nat_ips = array_values(array_filter(
            $_POST['nat_ips'] ?? [],
            fn($ip) => filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)
        ));
        $data['released'] = array_values(array_filter($managed_ips, fn($ip) => !in_array($ip, $nat_ips, true)));
        save_data($data);
        run_nat('apply');
        $msg = 'Applied.'; $mt = 'ok';
    } elseif ($act === 'net_add') {
        $br  = preg_replace('/[^a-z0-9]/', '', $_POST['bridge'] ?? 'vmbr0');
        $gw  = trim($_POST['gateway'] ?? '');
        $pfx = max(0, min(32, (int)($_POST['prefix'] ?? 29)));
        $ips = array_values(array_filter(
            array_map('trim', preg_split('/[\s,]+/', $_POST['ips'] ?? '')),
            fn($x) => filter_var($x, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)
        ));
        if (!$br || !filter_var($gw, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) || !$ips) {
            $msg = 'Valid bridge, gateway IP, and at least one public IP required.'; $mt = 'er';
        } else {
            $found = false;
            foreach ($data['networks'] as &$n) {
                if ($n['bridge'] === $br && $n['gateway'] === $gw) {
                    $n['ips']    = array_values(array_unique(array_merge($n['ips'] ?? [], $ips)));
                    $n['prefix'] = (string)$pfx;
                    $found       = true; break;
                }
            } unset($n);
            if (!$found) $data['networks'][] = ['bridge'=>$br,'gateway'=>$gw,'prefix'=>(string)$pfx,'ips'=>$ips];
            save_data($data);
            run_nat('apply');
            $msg = 'Saved and applied.'; $mt = 'ok';
        }
    } elseif ($act === 'net_del') {
        $i = (int)($_POST['idx'] ?? -1);
        if (isset($data['networks'][$i])) { array_splice($data['networks'], $i, 1); save_data($data); $msg = 'Network entry removed.'; $mt = 'ok'; }
    } elseif ($act === 'net_ip_del') {
        $i  = (int)($_POST['idx'] ?? -1); $ip2 = trim($_POST['ip'] ?? '');
        if (isset($data['networks'][$i]) && $ip2 !== '') {
            $data['networks'][$i]['ips'] = array_values(array_filter($data['networks'][$i]['ips'], fn($x) => $x !== $ip2));
            save_data($data); $msg = "Removed $ip2."; $mt = 'ok';
        }
    } elseif ($act === 'change_creds') {
        $cur = $_POST['cur_pass'] ?? ''; $nu = trim($_POST['new_user'] ?? '');
        $np  = $_POST['new_pass'] ?? ''; $np2 = $_POST['new_pass2'] ?? '';
        if (!password_verify($cur, $PASS_HASH))              { $msg = 'Current password is incorrect.'; $mt = 'er'; }
        elseif (!preg_match('/^[a-zA-Z0-9_\-]{1,64}$/', $nu)) { $msg = 'Username: 1–64 chars, letters/numbers/_ -.'; $mt = 'er'; }
        elseif (strlen($np) < 8)                              { $msg = 'New password must be at least 8 characters.'; $mt = 'er'; }
        elseif ($np !== $np2)                                  { $msg = 'Passwords do not match.'; $mt = 'er'; }
        else {
            $data['auth'] = ['user' => $nu, 'hash' => password_hash($np, PASSWORD_DEFAULT)];
            save_data($data);
            $_SESSION = []; session_destroy();
            header('Location: ?updated=1'); exit;
        }
    }

    $data         = load_data();
    $nets         = $data['networks']   ?? [];
    $host_ip      = $data['host_ip']    ?? '';
    $released_ips = $data['released']   ?? [];
    $stored_rules = $data['rules']      ?? [];
    $managed_ips  = array_merge(...array_map(fn($n) => $n['ips'] ?? [], $nets) ?: [[]]);
    $ip_br        = [];
    foreach ($nets as $n) foreach ($n['ips'] ?? [] as $ip) $ip_br[$ip] = $n['bridge'];
}

// ── Live state from host ──────────────────────────────────────────────────────
$live_rule_keys = [];
foreach (explode("\n", run_nat('list')) as $ln) {
    if (preg_match('/^(\d+)\s+DNAT\s+(\w+)\s+--\s+\S+\s+(\S+)\s+.*?dpt:(\d+)\s+to:(\S+)/', trim($ln), $m)) {
        $proto = $m[2] === '6' ? 'tcp' : ($m[2] === '17' ? 'udp' : strtolower($m[2]));
        $live_rule_keys[] = $proto . '|' . $m[3] . '|' . $m[4];
    }
}
$live_rule_keys = array_unique($live_rule_keys);

$host_bound = [];
foreach (explode("\n", trim(shell_exec("ip -o -4 addr show 2>/dev/null") ?? '')) as $ln)
    if (preg_match('/inet\s+(\S+)/', $ln, $m)) $host_bound[] = explode('/', $m[1])[0];

$live = [];
foreach (explode("\n", trim(shell_exec("ip -o -4 addr show 2>/dev/null") ?? '')) as $ln)
    if (preg_match('/^\d+:\s+(vmbr\S+)\s+inet\s+(\S+)/', $ln, $m)) $live[$m[1]][] = $m[2];

$tab = $_GET['tab'] ?? 'rules';
?>
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NAT Manager</title>
<script>(function(){document.documentElement.setAttribute('data-theme',localStorage.getItem('nmTheme')||'light');})();</script>
<style>
:root{--bg:#f5f5f2;--s:#fff;--s2:#fafaf8;--s3:#f0f0ec;--b:#e2e2da;--b2:#d4d4cc;--t:#111;--m:#666;--m2:#999;--ac:#2563eb;--ac2:#7c3aed;--gr:#16a34a;--re:#dc2626;--ye:#d97706;--bdg-tcp-bg:#eff6ff;--bdg-tcp-c:#2563eb;--bdg-tcp-b:#bfdbfe;--bdg-udp-bg:#fefce8;--bdg-udp-c:#a16207;--bdg-udp-b:#fde68a;--bdg-vm-bg:#fff7ed;--bdg-vm-c:#c2410c;--bdg-vm-b:#fed7aa;--msg-ok-bg:#f0fdf4;--msg-ok-c:#15803d;--msg-ok-b:#bbf7d0;--msg-er-bg:#fef2f2;--msg-er-c:#b91c1c;--msg-er-b:#fecaca;--msg-in-bg:#eff6ff;--msg-in-c:#1d4ed8;--msg-in-b:#bfdbfe;--shadow:0 1px 3px rgba(0,0,0,.08);--tog-icon:'☾';}
[data-theme=dark]{--bg:#0d0d0d;--s:#141414;--s2:#1a1a1a;--s3:#222;--b:#242424;--b2:#2e2e2e;--t:#f0f0f0;--m:#666;--m2:#444;--ac:#3b82f6;--ac2:#8b5cf6;--gr:#22c55e;--re:#ef4444;--ye:#f59e0b;--bdg-tcp-bg:rgba(59,130,246,.12);--bdg-tcp-c:#60a5fa;--bdg-tcp-b:rgba(59,130,246,.2);--bdg-udp-bg:rgba(245,158,11,.12);--bdg-udp-c:#fbbf24;--bdg-udp-b:rgba(245,158,11,.2);--bdg-vm-bg:rgba(234,88,12,.12);--bdg-vm-c:#fb923c;--bdg-vm-b:rgba(234,88,12,.2);--msg-ok-bg:rgba(34,197,94,.08);--msg-ok-c:#4ade80;--msg-ok-b:rgba(34,197,94,.2);--msg-er-bg:rgba(239,68,68,.08);--msg-er-c:#f87171;--msg-er-b:rgba(239,68,68,.2);--msg-in-bg:rgba(59,130,246,.08);--msg-in-c:#60a5fa;--msg-in-b:rgba(59,130,246,.2);--shadow:0 1px 3px rgba(0,0,0,.4);--tog-icon:'☀';}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,sans-serif;background:var(--bg);color:var(--t);font-size:14px;line-height:1.5;transition:background .15s,color .15s}a{color:inherit;text-decoration:none}
.top{background:var(--s);border-bottom:1px solid var(--b);padding:11px 20px;display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:10px;box-shadow:var(--shadow)}
.brand{display:flex;align-items:center;gap:10px}.ic3{width:30px;height:30px;background:linear-gradient(135deg,var(--ac),var(--ac2));border-radius:7px;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700;font-family:monospace;color:#fff;flex-shrink:0}
.brand h1{font-size:14px;font-weight:600}.brand p{font-size:10px;color:var(--m);font-family:monospace;margin-top:1px}.top-r{display:flex;gap:7px;align-items:center}
.btn{display:inline-flex;align-items:center;gap:5px;padding:7px 12px;border:none;border-radius:7px;font-size:12px;font-weight:500;cursor:pointer;line-height:1;font-family:inherit;transition:opacity .15s}.btn:disabled{opacity:.5;cursor:not-allowed}
.bpr{background:linear-gradient(135deg,var(--ac),var(--ac2));color:#fff}.bpr:hover:not(:disabled){opacity:.88}
.bgh{background:var(--s2);color:var(--t);border:1px solid var(--b2)}.bgh:hover:not(:disabled){background:var(--s3)}
.bdn{background:var(--msg-er-bg);color:var(--re);border:1px solid var(--msg-er-b)}.bdn:hover:not(:disabled){opacity:.8}
.bxs{padding:3px 8px;font-size:11px}
.out{padding:4px 9px;background:transparent;border:1px solid var(--b2);border-radius:5px;color:var(--m);font-size:11px;cursor:pointer;font-family:inherit}.out:hover{border-color:var(--re);color:var(--re)}
.tog3{padding:4px 9px;background:var(--s2);border:1px solid var(--b2);border-radius:5px;color:var(--m);font-size:12px;cursor:pointer;font-family:inherit}.tog3::after{content:var(--tog-icon)}.tog3:hover{border-color:var(--ac);color:var(--ac)}
.wrap{max-width:960px;margin:0 auto;padding:20px 18px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-bottom:16px}
.stat{background:var(--s);border:1px solid var(--b);border-radius:10px;padding:13px 15px;position:relative;overflow:hidden;box-shadow:var(--shadow)}.stat::before{content:'';position:absolute;top:0;left:0;right:0;height:3px;background:var(--ac)}
.st-g::before{background:var(--gr)}.st-p::before{background:var(--ac2)}.st-y::before{background:var(--ye)}
.sv{font-size:22px;font-weight:700;font-family:monospace}.sl{font-size:11px;color:var(--m);margin-top:3px}
.tabs{display:flex;border-bottom:1px solid var(--b);margin-bottom:16px}
.tab{padding:8px 16px;font-size:13px;color:var(--m);border-bottom:2px solid transparent;margin-bottom:-1px;cursor:pointer;transition:color .15s}.tab.on{color:var(--ac);border-bottom-color:var(--ac);font-weight:500}.tab:hover:not(.on){color:var(--t)}
.card{background:var(--s);border:1px solid var(--b);border-radius:10px;margin-bottom:13px;overflow:hidden;box-shadow:var(--shadow)}
.ch{padding:10px 15px;border-bottom:1px solid var(--b);font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.5px;color:var(--m);background:var(--s2);display:flex;align-items:center;justify-content:space-between;gap:8px}
.cb{padding:15px}.cb-np{padding:0}
table{width:100%;border-collapse:collapse}
th{font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.4px;color:var(--m);padding:8px 13px;text-align:left;border-bottom:1px solid var(--b);background:var(--s2);white-space:nowrap}
td{padding:9px 13px;border-bottom:1px solid var(--b);font-size:13px}tr:last-child td{border-bottom:none}tr:hover td{background:var(--s2)}
.mono{font-family:ui-monospace,monospace;font-size:12px}.er-row td{text-align:center;color:var(--m);padding:22px}
.grid{display:grid;gap:10px;align-items:end}.g-nat{grid-template-columns:1.4fr .5fr 1.4fr .5fr .45fr auto}.g2{grid-template-columns:1fr 1fr}.g3{grid-template-columns:1fr 1fr 1fr}
.fl{display:flex;flex-direction:column}.fl label{font-size:10px;font-weight:600;color:var(--m);margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px}
input[type=text],input[type=password],input[type=number],select,textarea{width:100%;padding:7px 10px;background:var(--s2);border:1px solid var(--b2);border-radius:7px;font-family:monospace;font-size:12.5px;color:var(--t);outline:none;transition:border-color .15s}
input:focus,select:focus,textarea:focus{border-color:var(--ac);background:var(--s)}textarea{resize:vertical;min-height:50px;font-size:12px}select option{background:var(--s)}
.bdg{display:inline-flex;font-size:10px;padding:2px 7px;border-radius:20px;font-weight:600;font-family:monospace}
.b-tcp{background:var(--bdg-tcp-bg);color:var(--bdg-tcp-c);border:1px solid var(--bdg-tcp-b)}.b-udp{background:var(--bdg-udp-bg);color:var(--bdg-udp-c);border:1px solid var(--bdg-udp-b)}
.b-nat{background:var(--bdg-tcp-bg);color:var(--bdg-tcp-c);border:1px solid var(--bdg-tcp-b)}.b-vm{background:var(--bdg-vm-bg);color:var(--bdg-vm-c);border:1px solid var(--bdg-vm-b)}
.b-live{background:rgba(22,163,74,.1);color:var(--gr);border:1px solid rgba(22,163,74,.25);font-size:9px;padding:1px 5px}.b-pend{background:rgba(217,119,6,.1);color:var(--ye);border:1px solid rgba(217,119,6,.25);font-size:9px;padding:1px 5px}
.pill{display:inline-flex;background:var(--s2);border:1px solid var(--b2);border-radius:5px;padding:2px 8px;font-family:monospace;font-size:11px;margin:2px;align-items:center;gap:4px}
.msg{padding:9px 13px;border-radius:7px;font-size:13px;margin-bottom:13px;display:flex;gap:8px;align-items:flex-start}
.msg.ok{background:var(--msg-ok-bg);color:var(--msg-ok-c);border:1px solid var(--msg-ok-b)}.msg.er{background:var(--msg-er-bg);color:var(--msg-er-c);border:1px solid var(--msg-er-b)}.msg.in{background:var(--msg-in-bg);color:var(--msg-in-c);border:1px solid var(--msg-in-b)}
.hint{font-size:11px;color:var(--m);margin-top:8px}.sep{border:none;border-top:1px solid var(--b);margin:18px 0}
.badge-cur{display:inline-block;font-family:monospace;font-size:12px;background:var(--s2);border:1px solid var(--b2);border-radius:5px;padding:3px 10px}
.strength{height:4px;border-radius:2px;margin-top:5px;transition:width .3s,background .3s}.pw-hint{font-size:10px;color:var(--m);margin-top:4px}
.ip-chk{width:16px;height:16px;cursor:pointer;accent-color:var(--ac)}
.stream-pre{font-family:ui-monospace,monospace;font-size:12px;line-height:1.75;margin:0;white-space:pre-wrap;color:var(--t);max-height:320px;overflow-y:auto}
@media(max-width:700px){.g-nat{grid-template-columns:1fr 1fr}.stats{grid-template-columns:1fr 1fr}.g3{grid-template-columns:1fr}}
</style></head><body>
<div class="top">
  <div class="brand"><div class="ic3">NAT</div>
    <div><h1>NAT Manager</h1><?php if ($host_ip) echo '<p>' . e($host_ip) . '</p>'; ?></div>
  </div>
  <div class="top-r">
    <span style="font-size:10px;color:var(--m);font-family:monospace">v<?= APP_VERSION ?></span>
    <button class="tog3" onclick="toggleTheme()" title="Toggle light/dark"></button>
    <a href="?logout=1" class="out" onclick="return confirm('Sign out?')">Logout</a>
  </div>
</div>

<div class="wrap">
<?php if ($msg): ?><div class="msg <?= e($mt) ?>"><?= $mt === 'ok' ? '✓' : ($mt === 'er' ? '✗' : 'i') ?>&nbsp;<?= e($msg) ?></div><?php endif; ?>

<div class="stats">
  <div class="stat">    <div class="sv"><?= count($stored_rules) ?></div><div class="sl">Rules in Config</div></div>
  <div class="stat st-p"><div class="sv"><?= count($nets) ?></div><div class="sl">Gateways</div></div>
  <div class="stat st-g"><div class="sv"><?= count($managed_ips) ?></div><div class="sl">Managed IPs</div></div>
  <div class="stat st-y"><div class="sv"><?= array_sum(array_map('count', $live)) ?></div><div class="sl">Live Addrs</div></div>
</div>

<div class="tabs">
  <a href="?tab=rules"    class="tab <?= $tab === 'rules' || $tab === '' ? 'on' : '' ?>">Port Forwarding</a>
  <a href="?tab=net"      class="tab <?= $tab === 'net'      ? 'on' : '' ?>">IPs &amp; Gateways</a>
  <a href="?tab=settings" class="tab <?= $tab === 'settings' ? 'on' : '' ?>">Settings</a>
</div>

<?php if ($tab === 'settings'): ?>
<div class="card"><div class="ch">Change Login Credentials</div><div class="cb">
  <div style="margin-bottom:16px"><div class="fl" style="margin-bottom:6px"><label>Current username</label></div><span class="badge-cur"><?= e($ADMIN_USER) ?></span></div>
  <form method="POST" action="?tab=settings" id="credForm" onsubmit="return validateCredForm()">
    <?= cf() ?><input type="hidden" name="action" value="change_creds">
    <div class="grid g3" style="margin-bottom:12px">
      <div class="fl"><label>Current password <span style="color:var(--re)">*</span></label><input type="password" name="cur_pass" id="cur_pass" autocomplete="current-password" required placeholder="Required"></div>
      <div class="fl"><label>New username</label><input type="text" name="new_user" id="new_user" autocomplete="username" value="<?= e($ADMIN_USER) ?>" pattern="[a-zA-Z0-9_\-]{1,64}"></div>
      <div class="fl"><label>&nbsp;</label><p class="pw-hint" style="margin-top:6px">Letters, numbers, _ or - (1–64 chars).</p></div>
    </div>
    <hr class="sep">
    <div class="grid g3" style="margin-bottom:14px">
      <div class="fl"><label>New password <span style="color:var(--m)">(optional)</span></label><input type="password" name="new_pass" id="new_pass" autocomplete="new-password" placeholder="Leave blank to keep" oninput="checkStrength(this.value)"><div class="strength" id="pwStrength" style="width:0;background:var(--re)"></div><p class="pw-hint" id="pwHint">Min 8 chars if changing</p></div>
      <div class="fl"><label>Confirm new password</label><input type="password" name="new_pass2" id="new_pass2" autocomplete="new-password" placeholder="Repeat" oninput="checkMatch()"><p class="pw-hint" id="matchHint">&nbsp;</p></div>
      <div class="fl"><label>&nbsp;</label><div style="display:flex;flex-direction:column;gap:8px;margin-top:6px"><button type="submit" class="btn bpr">Save Changes</button><p class="pw-hint">You will be signed out after saving.</p></div></div>
    </div>
  </form>
</div></div>
<div class="card"><div class="ch">Configuration File</div><div class="cb"><p style="font-size:13px;color:var(--m)">All settings, rules, and credentials are stored in:</p><p class="mono" style="margin-top:8px"><?= e(DATA_FILE) ?></p></div></div>

<?php elseif ($tab === 'net'): ?>
<div class="msg in">i Each gateway binds its IPs to the bridge and sends gratuitous ARP, making secondary public IPs reachable.</div>
<div class="card"><div class="ch">Add IPs / Gateway</div><div class="cb">
  <form method="POST" action="?tab=net"><?= cf() ?><input type="hidden" name="action" value="net_add">
    <div class="grid g2" style="margin-bottom:10px"><div class="fl"><label>Bridge</label><input name="bridge" value="vmbr0" required></div><div class="fl"><label>Gateway IP</label><input name="gateway" placeholder="Gateway IP" required></div></div>
    <div class="grid g2" style="margin-bottom:10px"><div class="fl"><label>Prefix (CIDR)</label><input type="number" name="prefix" value="29" min="1" max="32" required></div><div class="fl"><label>&nbsp;</label><button class="btn bpr">Save</button></div></div>
    <div class="fl"><label>Public IPs (space or comma separated)</label><textarea name="ips" placeholder="Enter public IP addresses"></textarea></div>
  </form>
</div></div>
<div class="card"><div class="ch">Configured Networks (<?= count($nets) ?>)</div><div class="cb-np" style="overflow-x:auto">
  <?php if (!$nets): ?><div style="padding:20px;text-align:center;color:var(--m)">No networks configured yet</div>
  <?php else: ?><table><thead><tr><th>Bridge</th><th>Gateway</th><th>Prefix</th><th>Managed IPs</th><th>Action</th></tr></thead><tbody>
  <?php foreach ($nets as $i => $n): ?>
    <tr><td class="mono"><?= e($n['bridge']) ?></td><td class="mono"><?= e($n['gateway']) ?></td><td class="mono">/<?= e($n['prefix']) ?></td>
    <td><?php foreach (($n['ips'] ?? []) as $ip) echo '<span class="pill">' . e($ip) . ' <a href="#" onclick="ipDel(event,' . $i . ',\'' . e($ip) . '\')" style="color:var(--re);font-size:11px">&#10005;</a></span>'; ?></td>
    <td><form method="POST" style="margin:0" onsubmit="return confirm('Remove this gateway entry?')"><?= cf() ?><input type="hidden" name="action" value="net_del"><input type="hidden" name="idx" value="<?= $i ?>"><button class="btn bdn bxs">Remove</button></form></td></tr>
  <?php endforeach; ?></tbody></table><?php endif; ?>
</div></div>
<div class="card"><div class="ch">Live Addresses on Bridges</div><div class="cb">
  <?php if (!$live): ?><span style="color:var(--m);font-size:13px">None detected</span>
  <?php else: foreach ($live as $br => $addrs): ?>
    <div style="margin-bottom:6px"><span style="font-family:monospace;font-size:12px;color:var(--m);margin-right:6px"><?= e($br) ?>:</span><?php foreach ($addrs as $a) echo '<span class="pill">' . e($a) . '</span>'; ?></div>
  <?php endforeach; endif; ?>
</div></div>
<form id="ipd" method="POST" action="?tab=net" style="display:none"><?= cf() ?><input type="hidden" name="action" value="net_ip_del"><input type="hidden" name="idx" id="ipdI"><input type="hidden" name="ip" id="ipdP"></form>

<?php else: ?>
<div class="card"><div class="ch">Add Port Forward</div><div class="cb">
  <form method="POST" action="?tab=rules"><?= cf() ?><input type="hidden" name="action" value="add_rule">
    <div class="grid g-nat">
      <div class="fl"><label>Public IP</label><input name="pub_ip" placeholder="<?= e($managed_ips[0] ?? 'Public IP') ?>" list="mips" required><datalist id="mips"><?php foreach ($managed_ips as $m) echo '<option value="' . e($m) . '">'; ?></datalist></div>
      <div class="fl"><label>Port</label><input type="number" name="pub_port" placeholder="Port" min="1" max="65535" required></div>
      <div class="fl"><label>Internal IP</label><input name="int_ip" placeholder="Internal host" required></div>
      <div class="fl"><label>Port</label><input type="number" name="int_port" placeholder="Port" min="1" max="65535" required></div>
      <div class="fl"><label>Proto</label><select name="proto"><option value="tcp">TCP</option><option value="udp">UDP</option></select></div>
      <div class="fl"><label>&nbsp;</label><button class="btn bpr">Add</button></div>
    </div>
  </form>
  <?php if (!$managed_ips): ?><div class="hint" style="color:var(--ye)">&#9888; No managed IPs — add them in <a href="?tab=net" style="color:var(--ac)">IPs &amp; Gateways</a> first.</div><?php endif; ?>
</div></div>

<div class="card">
  <div class="ch"><span>Port Forward Rules (<?= count($stored_rules) ?> in config)</span>
    <form method="POST" style="margin:0"><?= cf() ?><input type="hidden" name="action" value="sync_from_host"><button class="btn bgh bxs" title="Import rules from live iptables">&#8595; Sync from Host</button></form>
  </div>
  <div class="cb-np" style="overflow-x:auto"><table>
    <thead><tr><th>#</th><th>Public Endpoint</th><th></th><th>Destination</th><th>Proto</th><th>Status</th><th>Action</th></tr></thead>
    <tbody>
    <?php if (!$stored_rules): ?>
      <tr class="er-row"><td colspan="7">No rules in config yet. Add one above or use <em>&#8595; Sync from Host</em> to import.</td></tr>
    <?php else: foreach ($stored_rules as $idx => $r):
        $k       = $r['proto'] . '|' . $r['pub_ip'] . '|' . $r['pub_port'];
        $is_live = in_array($k, $live_rule_keys, true); ?>
      <tr><td class="mono" style="color:var(--m)"><?= ($idx + 1) ?></td>
        <td class="mono"><?= e($r['pub_ip']) ?>:<strong><?= e($r['pub_port']) ?></strong></td>
        <td style="color:var(--m2)">&#8594;</td><td class="mono"><?= e($r['int_ip']) ?>:<?= e($r['int_port']) ?></td>
        <td><span class="bdg b-<?= e($r['proto']) ?>"><?= strtoupper(e($r['proto'])) ?></span></td>
        <td><?php if ($is_live): ?><span class="bdg b-live">&#9679; live</span><?php else: ?><span class="bdg b-pend">&#9675; pending</span><?php endif; ?></td>
        <td><form method="POST" style="margin:0" onsubmit="return confirm('Delete this rule?')"><?= cf() ?><input type="hidden" name="action" value="del_rule"><input type="hidden" name="rule_idx" value="<?= $idx ?>"><button class="btn bdn bxs">Delete</button></form></td>
      </tr>
    <?php endforeach; endif; ?></tbody>
  </table></div>
</div>

<div class="card">
  <div class="ch"><span>IP Assignment &amp; Apply</span><span style="font-size:10px;color:var(--m);font-weight:400">&#9745; NAT — host claims IP &nbsp;|&nbsp; &#9744; VM — host releases IP</span></div>
  <div class="cb">
    <?php if (!$managed_ips): ?>
      <p style="color:var(--m);font-size:13px">No managed IPs — add them in <a href="?tab=net" style="color:var(--ac)">IPs &amp; Gateways</a> first.</p>
    <?php else: ?>
    <form method="POST" action="?tab=rules" id="syncModeForm"><?= cf() ?><input type="hidden" name="action" value="sync_mode">
      <table style="margin-bottom:14px"><thead><tr><th style="width:44px;text-align:center">NAT</th><th>IP</th><th>Bridge</th><th>Mode</th><th>Live State</th></tr></thead><tbody>
      <?php foreach ($managed_ips as $mip):
          $is_nat   = !in_array($mip, $released_ips, true);
          $is_bound = in_array($mip, $host_bound, true);
          $br       = $ip_br[$mip] ?? '—'; ?>
        <tr><td style="text-align:center"><input type="checkbox" class="ip-chk" name="nat_ips[]" value="<?= e($mip) ?>" id="chk_<?= e(str_replace('.', '_', $mip)) ?>" <?= $is_nat ? 'checked' : '' ?> onchange="updateRow('<?= e($mip) ?>')"></td>
          <td class="mono" style="font-weight:500"><?= e($mip) ?></td>
          <td class="mono" style="color:var(--m)"><?= e($br) ?></td>
          <td id="badge_<?= e(str_replace('.', '_', $mip)) ?>"><span class="bdg <?= $is_nat ? 'b-nat' : 'b-vm' ?>"><?= $is_nat ? 'NAT' : 'VM' ?></span></td>
          <td><?php if ($is_bound): ?><span style="color:var(--gr);font-size:12px">&#9679; host-bound</span><?php else: ?><span style="color:var(--m);font-size:12px">&#9675; released</span><?php endif; ?></td>
        </tr>
      <?php endforeach; ?></tbody></table>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <button type="button" class="btn bpr" id="applyBtn" onclick="doApply()">Apply</button>
        <span style="font-size:11px;color:var(--m)">Saves mode then applies all rules and IP bindings to the host.</span>
      </div>
    </form>
    <?php endif; ?>
  </div>
</div>

<div class="card" id="applyOutputCard" style="display:none">
  <div class="ch" style="justify-content:space-between"><span>Apply Output</span>
    <button onclick="document.getElementById('applyOutputCard').style.display='none'" style="background:none;border:none;color:var(--m);cursor:pointer;font-size:16px;line-height:1">&#10005;</button>
  </div>
  <div class="cb" style="padding:12px 15px"><pre class="stream-pre" id="applyPre"></pre></div>
</div>
<?php endif; ?>
</div>

<script>
function toggleTheme(){var r=document.documentElement;var t=r.getAttribute('data-theme')==='dark'?'light':'dark';r.setAttribute('data-theme',t);localStorage.setItem('nmTheme',t);}
function ipDel(e,i,ip){e.preventDefault();if(!confirm('Remove '+ip+' from config?'))return;document.getElementById('ipdI').value=i;document.getElementById('ipdP').value=ip;document.getElementById('ipd').submit();}
function updateRow(ip){var k=ip.replace(/\./g,'_');var cb=document.getElementById('chk_'+k);var b=document.getElementById('badge_'+k);if(!cb||!b)return;b.innerHTML=cb.checked?'<span class="bdg b-nat">NAT</span>':'<span class="bdg b-vm">VM</span>';}
function fmtLine(s){var x=s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  if(x.startsWith('[BIND]')||x.startsWith('[RULE]'))return'<span style="color:var(--gr)">'+x+'</span>';
  if(x.startsWith('[ARP]'))return'<span style="color:var(--ac)">'+x+'</span>';
  if(x.startsWith('[EXISTS]'))return'<span style="color:var(--m)">'+x+'</span>';
  if(x.startsWith('[RELEASE]')||x.startsWith('[VM]'))return'<span style="color:var(--ye)">'+x+'</span>';
  if(x.startsWith('[FAIL]')||x.startsWith('[WARN]'))return'<span style="color:var(--re)">'+x+'</span>';
  if(x==='apply complete')return'<span style="color:var(--gr);font-weight:600">&#10003; apply complete</span>';
  return x;}
function doApply(){
  var form=document.getElementById('syncModeForm'),btn=document.getElementById('applyBtn');
  var card=document.getElementById('applyOutputCard'),pre=document.getElementById('applyPre');
  card.style.display='block';pre.innerHTML='<span style="color:var(--m)">Applying\u2026</span>\n';
  card.scrollIntoView({behavior:'smooth',block:'nearest'});btn.disabled=true;btn.textContent='Applying\u2026';
  var fd=new FormData(form);
  if(!window.fetch||!window.ReadableStream){form.submit();return;}
  fetch('?stream=apply',{method:'POST',body:fd}).then(function(r){
    if(!r.ok)throw new Error('HTTP '+r.status);
    var reader=r.body.getReader(),dec=new TextDecoder(),buf='';pre.innerHTML='';
    function pump(){return reader.read().then(function(c){
      if(c.done){btn.disabled=false;btn.textContent='Apply';return;}
      buf+=dec.decode(c.value,{stream:true});
      var parts=buf.split('\n');buf=parts.pop();
      parts.forEach(function(p){if(p.indexOf('data: ')===0){try{var d=JSON.parse(p.slice(6));
        if(d==='__done__'){btn.disabled=false;btn.textContent='Apply';return;}
        pre.innerHTML+=fmtLine(d)+'\n';pre.scrollTop=pre.scrollHeight;}catch(e){}}});return pump();});}
    return pump();}).catch(function(e){pre.innerHTML+='<span style="color:var(--re)">Error: '+e.message+'</span>\n';btn.disabled=false;btn.textContent='Apply';});}
function checkStrength(v){var el=document.getElementById('pwStrength'),h=document.getElementById('pwHint');if(!el)return;if(!v){el.style.width='0';h.textContent='Min 8 chars if changing';return;}var s=0;if(v.length>=8)s++;if(v.length>=12)s++;if(/[A-Z]/.test(v))s++;if(/[0-9]/.test(v))s++;if(/[^A-Za-z0-9]/.test(v))s++;var c=['var(--re)','var(--ye)','var(--ye)','var(--gr)','var(--gr)'],l=['Too short','Weak','Fair','Strong','Very strong'];el.style.width=(s*20)+'%';el.style.background=c[Math.min(s,4)];h.textContent=l[Math.min(s,4)];}
function checkMatch(){var p=document.getElementById('new_pass').value,c=document.getElementById('new_pass2').value,h=document.getElementById('matchHint');if(!h)return;if(!c){h.textContent='\u00a0';h.style.color='var(--m)';return;}if(p===c){h.textContent='\u2713 Passwords match';h.style.color='var(--gr)';}else{h.textContent='\u2717 Passwords do not match';h.style.color='var(--re)';}}
function validateCredForm(){var cur=document.getElementById('cur_pass').value;if(!cur){alert('Current password is required.');return false;}var np=document.getElementById('new_pass').value,nc=document.getElementById('new_pass2').value;if(np&&np.length<8){alert('New password must be at least 8 characters.');return false;}if(np&&np!==nc){alert('Passwords do not match.');return false;}var nu=document.getElementById('new_user').value;if(!/^[a-zA-Z0-9_\-]{1,64}$/.test(nu)){alert('Invalid username format.');return false;}return confirm('Save credentials? You will be signed out immediately.');}
</script>
</body></html>

NMWEBUI_INDEX_PHP
}

# ── write_natmgr: write /usr/local/bin/nat-mgr ────────────────────────────────
write_natmgr() {
cat > "$NATMGR" << 'NATMGR_CONTENT'
#!/bin/bash
# nat-mgr — privileged NAT helper for nat-manager-webui
# Invoked via: sudo /usr/local/bin/nat-mgr <command> [args]
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DATA="/var/www/html/nat-manager-webui/.htdata.json"
RULES="/etc/iptables/rules.v4"
LOG="/var/log/nat-manager.log"

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
out(){ echo "$*"; log "$*"; }
save_rules(){ iptables-save > "$RULES"; }

valid_ip(){
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for o in "$a" "$b" "$c" "$d"; do [ "$o" -le 255 ] || return 1; done; return 0
}

get_host_ip(){ python3 -c "import json;d=json.load(open('$DATA'));print(d.get('host_ip',''))" 2>/dev/null || true; }
get_int_br(){  python3 -c "import json;d=json.load(open('$DATA'));print(d.get('internal',{}).get('bridge','vmbr1'))" 2>/dev/null || echo "vmbr1"; }
get_int_net(){ python3 -c "import json;d=json.load(open('$DATA'));print(d.get('internal',{}).get('network','192.168.1.0/24'))" 2>/dev/null || echo "192.168.1.0/24"; }

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in

  # ── list: show live PREROUTING rules ──────────────────────────────────────
  list)
    iptables -t nat -L PREROUTING -n --line-numbers ;;

  # ── apply: flush DNAT rules then re-apply everything from .htdata.json ──────
  apply)
    log "apply start"
    # Flush PREROUTING (removes old DNAT + RETURN rules)
    iptables -t nat -F PREROUTING
    # Re-add RETURN guard for host IP
    HOST_IP="$(get_host_ip)"
    [ -n "$HOST_IP" ] && iptables -t nat -A PREROUTING -d "$HOST_IP" -j RETURN
    # Re-apply all DNAT rules from .htdata.json
    python3 - "$DATA" << 'PY'
import json, subprocess, sys
try: d=json.load(open(sys.argv[1]))
except Exception as e: print(f"[WARN]    .htdata.json read error: {e}"); sys.exit(0)
rules=d.get("rules",[])
if not rules: print("[WARN]    No rules in config")
for r in rules:
    pi=str(r.get("pub_ip","")); pp=str(r.get("pub_port",""))
    ii=str(r.get("int_ip","")); ip=str(r.get("int_port",""))
    pr=str(r.get("proto","tcp"))
    if not (pi and pp and ii and ip): continue
    cmd=["iptables","-t","nat","-A","PREROUTING","-d",pi,"-p",pr,"--dport",pp,"-j","DNAT","--to-destination",f"{ii}:{ip}"]
    r2=subprocess.run(cmd,capture_output=True)
    if r2.returncode==0: print(f"[RULE]    {pi}:{pp} → {ii}:{ip} ({pr})")
    else: print(f"[FAIL]    {pi}:{pp} → {ii}:{ip}: {r2.stderr.decode().strip()}")
PY
    # Sync IPs (bind NAT IPs, release VM IPs)
    INT_BR="$(get_int_br)"
    INT_NET="$(get_int_net)"
    GWD=$(ip route | awk '/default/{print $3; exit}')
    python3 - "$DATA" << 'PY' | while IFS='|' read -r BR GW PFX IP MODE; do
import json, sys
try: d=json.load(open(sys.argv[1]))
except: d={}
rel=set(d.get("released",[]))
gwd=""
for n in d.get("networks",[]):
    b=n.get("bridge","vmbr0"); g=n.get("gateway",""); p=str(n.get("prefix","29"))
    for ip in n.get("ips",[]):
        if ip: print(f"{b}|{g}|{p}|{ip}|{'rel' if ip in rel else 'nat'}")
PY
      [ -z "$MODE" ] && MODE="nat"
      [ -z "$IP" ] && continue
      [ -z "$GW" ] && GW="$GWD"
      BR_MAC=$(cat "/sys/class/net/${BR}/address" 2>/dev/null || true)
      if [ "$MODE" = "rel" ]; then
        if ip addr show "$BR" 2>/dev/null | grep -qw "${IP}/${PFX}"; then
          ip addr del "${IP}/${PFX}" dev "$BR" 2>/dev/null \
            && out "[RELEASE] $IP — released from $BR (VM mode)" \
            || out "[WARN]    $IP — could not release"
        else out "[VM]      $IP — already released"; fi
      else
        if ip addr show "$BR" 2>/dev/null | grep -qw "${IP}/${PFX}"; then
          out "[EXISTS]  $IP already bound on $BR"
        else
          ip addr add "${IP}/${PFX}" dev "$BR" 2>/dev/null \
            && out "[BIND]    $IP/$PFX → $BR" || out "[FAIL]    $IP"
        fi
        [ -n "$GW" ] && arping -c 3 -U -I "$BR" -s "$IP" "$GW" >/dev/null 2>&1 \
          && out "[ARP]     $IP → $GW"
      fi
    done
    save_rules
    out "apply complete" ;;

  # ── sync-host: read current iptables + bound IPs → JSON ───────────────────
  sync-host)
    python3 - << 'PY'
import subprocess, json, re, sys
rules=[]
try:
    out=subprocess.check_output(['iptables','-t','nat','-S','PREROUTING'],text=True,stderr=subprocess.DEVNULL)
    for line in out.splitlines():
        m=re.search(r'-d\s+(\S+?)\s+.*?-p\s+(\w+).*?--dport\s+(\d+).*?--to-destination\s+(\S+)',line)
        if m and 'DNAT' in line:
            pub_ip=m.group(1).split('/')[0]; proto=m.group(2)
            pub_port=int(m.group(3)); dest=m.group(4)
            int_ip,int_port=dest.rsplit(':',1)
            rules.append({"proto":proto,"pub_ip":pub_ip,"pub_port":pub_port,"int_ip":int_ip,"int_port":int(int_port)})
except Exception as e: pass
bound={}
try:
    out=subprocess.check_output(['ip','-o','-4','addr','show'],text=True,stderr=subprocess.DEVNULL)
    for line in out.splitlines():
        m=re.match(r'\d+:\s+(vmbr\S+)\s+inet\s+(\S+)',line)
        if m:
            br=m.group(1); ip_cidr=m.group(2)
            if br not in bound: bound[br]=[]
            bound[br].append(ip_cidr.split('/')[0])
except: pass
print(json.dumps({"rules":rules,"bound":bound},indent=2))
PY
    ;;

  # ── restore: restore iptables from saved rules file ───────────────────────
  restore)
    [ -f "$RULES" ] && iptables-restore < "$RULES" && out "restored" || out "[WARN] no rules file" ;;

  # ── save ──────────────────────────────────────────────────────────────────
  save) save_rules; echo "saved" ;;

  *) echo "usage: nat-mgr {list|apply|sync-host|restore|save}"; exit 1 ;;
esac

NATMGR_CONTENT
    chmod 755 "$NATMGR"; chown root:root "$NATMGR" 2>/dev/null || true
}

# ── inject_creds: sed-replace placeholders in INDEX ────────────────────────────
inject_creds() {
    # Credentials and config live in .htdata.json
    : # no-op
}

# ── extract_creds: read ADMIN_USER + PASS_HASH from existing index.php ─────────
extract_creds() {
    local idx="${1:-$INDEX}"
    [ -f "$idx" ] || { warn "index.php not found at $idx"; return 1; }
    CUR_USER=$(grep "^const ADMIN_USER" "$idx" | sed "s/.*= '//;s/';.*//")
    CUR_HASH=$(grep "^const PASS_HASH"  "$idx" | sed "s/.*= '//;s/';.*//")
    [ -n "$CUR_USER" ] && [ -n "$CUR_HASH" ]
}

# ── finalize_perms: ensure all web files owned by www-data ──────────────
finalize_perms() {
    # Webroot: index.php + .htdata.json both live here
    mkdir -p "$WEBROOT"
    chown -R www-data:www-data "$WEBROOT"
    chmod 755 "$WEBROOT"
    find "$WEBROOT" -type f -exec chmod 644 {} \;
    ok "Webroot ownership set: www-data:www-data (755/644)"
}

# ── setup_system: sudoers, sysctl, systemd, base iptables ─────────────────────
setup_system() {
    local PB="$1" HOSTIP="$2" IB="$3" INET="$4"

    # ip_forward
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "net.ipv4.ip_forward=1" > "$SYSCTL"
    ok "ip_forward enabled"

    # base iptables (idempotent)
    add_once(){ local tbl="$1"; shift; iptables -t "$tbl" -C "$@" 2>/dev/null || iptables -t "$tbl" -A "$@"; }
    add_once nat    PREROUTING  -d "$HOSTIP" -j RETURN
    add_once filter FORWARD     -i "$PB" -o "$IB" -j ACCEPT
    add_once filter FORWARD     -i "$IB" -o "$PB" -m state --state RELATED,ESTABLISHED -j ACCEPT
    add_once nat    POSTROUTING -s "$INET" -o "$PB" -j MASQUERADE
    add_once nat    POSTROUTING -s "$INET" -o "$IB" -j MASQUERADE
    mkdir -p /etc/iptables; iptables-save > "$RULES"; chmod 644 "$RULES"
    ok "iptables base rules configured"

    # sudoers
    cat > "$SUDOERS" << SUDO
Defaults:www-data !requiretty
www-data ALL=(root) NOPASSWD: ${NATMGR}
SUDO
    chmod 440 "$SUDOERS"
    visudo -cf "$SUDOERS" >/dev/null 2>&1 && ok "sudoers rule set" || die "sudoers validation failed"

    # systemd boot unit
    cat > "$UNIT" << UNITEOF
[Unit]
Description=nat-manager-webui (restore NAT rules + bind/announce IPs)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${NATMGR} restore
ExecStart=${NATMGR} sync
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNITEOF
    systemctl daemon-reload
    systemctl enable nat-manager-webui.service >/dev/null 2>&1
    ok "boot persistence enabled"
}

# Write .htdata.json using Python + environment variables.
# Passes all values through env vars into a single-quoted heredoc — no bash JSON quoting.
# NM_NETS format: one line per gateway: "bridge|gateway|prefix|ip1 ip2 ip3 ..."
write_htdata() {
    local au="$1" hash="$2" hostip="$3" ib="$4" inet="$5" data="$6" nets_str="$7"
    _NM_USER="$au" _NM_HASH="$hash" _NM_HOSTIP="$hostip"     _NM_IB="$ib"   _NM_INET="$inet" _NM_DATA="$data"     _NM_NETS="$nets_str"     python3 << 'NMPY'
import json, os

nets = []
for entry in os.environ.get('_NM_NETS', '').strip().splitlines():
    entry = entry.strip()
    if not entry:
        continue
    parts = entry.split('|', 3)
    if len(parts) < 4:
        continue
    bridge, gw, pfx, ips_str = parts
    ips = [ip.strip() for ip in ips_str.split() if ip.strip()]
    if gw:
        nets.append({"bridge": bridge, "gateway": gw, "prefix": pfx, "ips": ips})

d = {
    "auth":     {"user": os.environ["_NM_USER"], "hash": os.environ["_NM_HASH"]},
    "host_ip":  os.environ["_NM_HOSTIP"],
    "internal": {"bridge": os.environ["_NM_IB"], "network": os.environ["_NM_INET"]},
    "networks": nets,
    "released": [],
    "rules":    []
}
with open(os.environ["_NM_DATA"], "w") as f:
    json.dump(d, f, indent=2)
NMPY
}

# =============================================================================
# INSTALL
# =============================================================================
do_install() {
    echo -e "\n${BD}${C}=== nat-manager-webui — install ===${N}\n"

    # detect defaults
    DIP=$(ip -o -4 addr show vmbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -z "$DIP" ] && DIP=$(hostname -I | awk '{print $1}')
    DPFX=$(ip -o -4 addr show vmbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f2 | head -1); DPFX="${DPFX:-29}"
    DGW=$(ip route | awk '/default/{print $3; exit}')
    DPB=$(ip -o link show 2>/dev/null | grep -oP 'vmbr\d+' | sort -u | head -1); DPB="${DPB:-vmbr0}"
    DIB=$(ip -o link show 2>/dev/null | grep -oP 'vmbr\d+' | grep -v "^${DPB}$" | head -1); DIB="${DIB:-vmbr1}"
    DINET=$(ip -o -4 addr show "$DIB" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -n "$DINET" ]; then
        DINET=$(python3 -c "import ipaddress;print(ipaddress.IPv4Interface('$DINET').network)" 2>/dev/null || echo "192.168.1.0/24")
    else DINET="192.168.1.0/24"; fi

    echo -e "  ${Y}Press Enter to accept detected values${N}\n"
    read -p "  Public bridge   [${DPB}]:  " I; PB="${I:-$DPB}"
    read -p "  Host public IP  [${DIP}]:  " I; HOSTIP="${I:-$DIP}"
    read -p "  Public CIDR     [${DPFX}]: " I; PFX="${I:-$DPFX}"
    read -p "  Gateway         [${DGW}]:  " I; GW="${I:-$DGW}"
    SUG=$(python3 -c "
import ipaddress
try:
    net=ipaddress.IPv4Network('${HOSTIP}/${PFX}',strict=False)
    out=[str(h) for h in net.hosts() if str(h) not in ('${HOSTIP}','${GW}')]
    print(' '.join(out))
except: print('')" 2>/dev/null)
    read -p "  Managed IPs     [${SUG}]: " I; PIPS="${I:-$SUG}"
    read -p "  Internal bridge [${DIB}]: "  I; IB="${I:-$DIB}"
    read -p "  Internal network[${DINET}]: " I; INET="${I:-$DINET}"

    NM_NETS="${PB}|${GW}|${PFX}|${PIPS}"
    while true; do
        echo ""; read -p "  Add another gateway? [y/N]: " M; [[ "$M" =~ ^[Yy]$ ]] || break
        read -p "    Bridge [vmbr0]: " I; AB="${I:-vmbr0}"
        read -p "    Gateway IP:     " AG; [ -z "$AG" ] && { warn "skipped"; continue; }
        read -p "    CIDR prefix [29]: " I; AP="${I:-29}"
        read -p "    Public IPs (space separated): " AIPS
        NM_NETS="${NM_NETS}\n${AB}|${AG}|${AP}|${AIPS}"
        ok "Gateway ${AG} added"
    done

    echo ""
    read -p "  Admin username [admin]: " I; AU="${I:-admin}"
    while true; do
        read -s -p "  Admin password: " AP1; echo ""
        read -s -p "  Confirm:        " AP2; echo ""
        [ -n "$AP1" ] && [ "$AP1" = "$AP2" ] && break
        warn "Empty or mismatch — try again"
    done
    echo ""; read -p "  Proceed? [y/N]: " Cf; [[ "$Cf" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
    echo ""

    info "Installing packages..."
    apt-get update -y >/dev/null 2>&1
    apt-get install -y apache2 php libapache2-mod-php iptables sudo iputils-arping python3 >/dev/null 2>&1
    ok "Packages installed"

    # write app files
    mkdir -p "$WEBROOT"
    chown root:root "$WEBROOT"; chmod 755 "$WEBROOT"
    write_index
    ok "index.php written"

    # Create data directory outside webroot (not web-accessible — holds credentials)
    # Write .htdata.json with credentials + full config
    HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$AP1")

    write_htdata "$AU" "$HASH" "$HOSTIP" "$IB" "$INET" "$DATA" "$NM_NETS"
    chown www-data:www-data "$DATA"; chmod 644 "$DATA"
    ok ".htdata.json written"

    write_natmgr
    ok "nat-mgr written"

    setup_system "$PB" "$HOSTIP" "$IB" "$INET"


    systemctl enable apache2 >/dev/null 2>&1
    systemctl restart apache2 && ok "Apache running"
    finalize_perms
    "$NATMGR" sync >/dev/null 2>&1 && ok "IPs bound and announced"

    echo ""
    echo -e "${BD}${C}==== Install complete ====${N}"
    echo -e "  URL   : ${BD}http://${HOSTIP}/nat-manager-webui/${N}"
    echo -e "  Login : ${AU}"
    echo ""
}

# =============================================================================
# UPDATE  (index.php + nat-mgr only — preserves data.json + credentials)
# =============================================================================
do_update() {
    echo -e "\n${BD}${C}=== nat-manager-webui — update ===${N}\n"
    [ -f "$INDEX" ] || die "No existing install at $INDEX — run: $0 install"

    # Migrate data.json from old webroot location if needed
    OLD_DATA="${WEBROOT}/.htdata.json"
    if [ -f "$OLD_DATA" ] && [ ! -f "$DATA" ]; then
            mv "$OLD_DATA" "$DATA"
        ok "Migrated data.json from webroot to $DATA"
    fi
    [ -f "$DATA" ] || die "No data file at $DATA — run: $0 install"
    info "Updating app files, data.json preserved at $DATA"

    write_index
    inject_creds "$CUR_USER" "$CUR_HASH"
    ok "index.php updated"

    write_natmgr
    ok "nat-mgr updated"

    info "Running sync..."
    "$NATMGR" sync
    ok "Sync complete"
    finalize_perms

    echo ""
    echo -e "${BD}${C}==== Update complete ====${N}"
    echo -e "  index.php and nat-mgr updated."
    echo -e "  data.json, credentials and system config unchanged."
    echo ""
}

# =============================================================================
# REINSTALL  (full re-setup — preserves data.json + credentials)
# =============================================================================
do_reinstall() {
    echo -e "\n${BD}${C}=== nat-manager-webui — reinstall ===\n${N}"

    # ── Check existing installation ────────────────────────────────────────────
    hdr "Checking existing installation"
    EX_DIR=0; EX_INDEX=0; EX_DATA=0
    present "$WEBROOT"  && { EX_DIR=1;   ok   "Webroot exists : $WEBROOT"; } || info "Webroot not found : $WEBROOT"
    present "$INDEX"    && { EX_INDEX=1; ok   "index.php found: $INDEX"; }   || info "index.php missing: $INDEX"
    present "$DATA"     && { EX_DATA=1;  ok   "data.json found: $DATA";  }   || info "data.json missing: $DATA"
    if [ "$EX_DATA" -eq 1 ]; then
        echo ""
        echo -e "  ${BD}Current data.json contents:${N}"
        python3 - << 'PY'
import json, sys
try:
    d=json.load(open("/var/www/html/nat-manager-webui/.htdata.json"))
    u=d.get("auth",{}).get("user","?")
    hi=d.get("host_ip","?")
    nr=len(d.get("rules",[]))
    nn=len(d.get("networks",[]))
    ni=sum(len(n.get("ips",[])) for n in d.get("networks",[]))
    print(f"    Login user : {u}")
    print(f"    Host IP    : {hi}")
    print(f"    Networks   : {nn}  |  Managed IPs: {ni}  |  Rules: {nr}")
except Exception as e:
    print(f"    (Could not parse data.json: {e})")
PY
    fi

    # ── Ask: keep or replace data.json ────────────────────────────────────────
    KEEP_DATA=0
    if [ -f "$DATA" ]; then
        echo -e "  ${BD}Existing network config found in data.json:${N}"
        python3 - << 'PY'
import json
try:
    d=json.load(open("/var/lib/nat-manager-webui/data.json"))
    print("    Host IP  :", d.get("host_ip","?"))
    for n in d.get("networks",[]):
        print("    Gateway  : %s via %s/%s  IPs: %s" % (
            n.get("bridge","?"), n.get("gateway","?"), n.get("prefix","?"),
            ", ".join(n.get("ips",[])) or "none"))
except Exception as e:
    print("    (could not read data.json:", e, ")")
PY
        echo ""
        if [[ "$(ask "Keep existing network config and data.json?")" =~ ^[Yy]$ ]]; then
            KEEP_DATA=1
        else
            warn "Wiping data.json and starting fresh"
        fi
    else
        warn "No data.json found — will set up fresh config"
    fi

    # ── Credentials: depends on whether we keep data ──────────────────────────
    echo ""
    if [ "$KEEP_DATA" -eq 1 ]; then
        # Auto-extract from existing index.php
        if extract_creds 2>/dev/null; then
            info "Preserving credentials for user: $CUR_USER"
            AU="$CUR_USER"; AHASH="$CUR_HASH"
        else
            warn "Could not read existing credentials — please set new ones"
            read -p "  Admin username [admin]: " I; AU="${I:-admin}"
            while true; do
                read -s -p "  Admin password: " AP1; echo ""
                read -s -p "  Confirm:        " AP2; echo ""
                [ -n "$AP1" ] && [ "$AP1" = "$AP2" ] && break
                warn "Empty or mismatch — try again"
            done
            AHASH=$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$AP1")
        fi
    else
        # Fresh start — clean webroot, ask for new credentials
        if present "$WEBROOT"; then
            info "Removing all existing files in $WEBROOT..."
            rm -rf "${WEBROOT:?}/"
            mkdir -p "$WEBROOT"
            ok "Webroot wiped and recreated: $WEBROOT"
        fi
        echo ""
        echo -e "  ${BD}Set new login credentials:${N}"
        read -p "  Admin username [admin]: " I; AU="${I:-admin}"
        while true; do
            read -s -p "  Admin password: " AP1; echo ""
            read -s -p "  Confirm:        " AP2; echo ""
            [ -n "$AP1" ] && [ "$AP1" = "$AP2" ] && break
            warn "Empty or mismatch — try again"
        done
        AHASH=$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$AP1")
    fi

    # ── Network config ─────────────────────────────────────────────────────────
    if [ "$KEEP_DATA" -eq 0 ]; then
        echo ""
        info "Enter new network configuration:"
        DIP=$(ip -o -4 addr show vmbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        DPFX=$(ip -o -4 addr show vmbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f2 | head -1); DPFX="${DPFX:-29}"
        DGW=$(ip route | awk '/default/{print $3; exit}')
        DPB=$(ip -o link show 2>/dev/null | grep -oP 'vmbr\d+' | sort -u | head -1); DPB="${DPB:-vmbr0}"
        DIB=$(ip -o link show 2>/dev/null | grep -oP 'vmbr\d+' | grep -v "^${DPB}$" | head -1); DIB="${DIB:-vmbr1}"
        DINET=$(ip -o -4 addr show "$DIB" 2>/dev/null | awk '{print $4}' | head -1)
        [ -n "$DINET" ] && DINET=$(python3 -c "import ipaddress;print(ipaddress.IPv4Interface('$DINET').network)" 2>/dev/null || echo "192.168.1.0/24") || DINET="192.168.1.0/24"
        echo ""
        read -p "  Public bridge   [${DPB}]:  " I; PB="${I:-$DPB}"
        read -p "  Host public IP  [${DIP}]:  " I; HOSTIP="${I:-$DIP}"
        read -p "  Public CIDR     [${DPFX}]: " I; PFX="${I:-$DPFX}"
        read -p "  Gateway         [${DGW}]:  " I; GW="${I:-$DGW}"
        SUG=$(python3 -c "
import ipaddress
try:
    net=ipaddress.IPv4Network('${HOSTIP}/${PFX}',strict=False)
    out=[str(h) for h in net.hosts() if str(h) not in ('${HOSTIP}','${GW}')]
    print(' '.join(out))
except: print('')" 2>/dev/null)
        read -p "  Managed IPs     [${SUG}]: " I; PIPS="${I:-$SUG}"
        read -p "  Internal bridge [${DIB}]: "  I; IB="${I:-$DIB}"
        read -p "  Internal network[${DINET}]: " I; INET="${I:-$DINET}"
        NM_NETS="${PB}|${GW}|${PFX}|${PIPS}"
        while true; do
            echo ""; read -p "  Add another gateway? [y/N]: " M; [[ "$M" =~ ^[Yy]$ ]] || break
            read -p "    Bridge [vmbr0]: " I; AB="${I:-vmbr0}"
            read -p "    Gateway IP:     " AG; [ -z "$AG" ] && { warn "skipped"; continue; }
            read -p "    CIDR prefix [29]: " I; AP="${I:-29}"
            read -p "    Public IPs (space separated): " AIPS
            NM_NETS="${NM_NETS}\n${AB}|${AG}|${AP}|${AIPS}"
            ok "Gateway ${AG} added"
        done
    else
        PB=$(python3 -c "import json;d=json.load(open('$DATA'));print(d.get('networks',[{}])[0].get('bridge','vmbr0'))" 2>/dev/null || echo "vmbr0")
        HOSTIP=$(python3 -c "import json;d=json.load(open('$DATA'));print(d.get('host_ip',''))" 2>/dev/null || echo "")
        IB=$(python3 -c "import json;d=json.load(open('$DATA'));print(d.get('internal',{}).get('bridge','vmbr1'))" 2>/dev/null || echo "vmbr1")
        INET=$(python3 -c "import json;d=json.load(open('$DATA'));print(d.get('internal',{}).get('network','192.168.1.0/24'))" 2>/dev/null || echo "192.168.1.0/24")
        [ -z "$HOSTIP" ] && HOSTIP=$(ip -o -4 addr show vmbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    fi

    echo ""; read -p "  Proceed with reinstall? [y/N]: " Cf
    [[ "$Cf" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
    echo ""

    info "Installing packages..."
    apt-get update -y >/dev/null 2>&1
    apt-get install -y apache2 php libapache2-mod-php iptables sudo iputils-arping python3 >/dev/null 2>&1
    ok "Packages installed"

    mkdir -p "$WEBROOT"
    write_index
    inject_creds "$AU" "$AHASH"
    ok "index.php written"

    if [ "$KEEP_DATA" -eq 0 ]; then
    
        # Write temp helper for data.php creation (avoids bash/PHP string quoting conflicts)
                write_htdata "$AU" "$AHASH" "$HOSTIP" "$IB" "$INET" "$DATA" "$NM_NETS"
        chown www-data:www-data "$DATA"; chmod 644 "$DATA"
        ok ".htdata.json written"
    else
        # Migrate data.json from old webroot location if needed
        OLD_DATA="${WEBROOT}/.htdata.json"
        if [ -f "$OLD_DATA" ] && [ ! -f "$DATA" ]; then
                    mv "$OLD_DATA" "$DATA"
            ok "Migrated data.json from webroot to $DATA"
        fi
            ok "data.json preserved"
    fi

    write_natmgr
    ok "nat-mgr written"

    setup_system "$PB" "$HOSTIP" "$IB" "$INET"


    systemctl enable apache2 >/dev/null 2>&1
    systemctl restart apache2 && ok "Apache running"
    finalize_perms
    "$NATMGR" sync >/dev/null 2>&1 && ok "IPs bound and announced"

    echo ""
    echo -e "${BD}${C}==== Reinstall complete ====\n${N}"
    if [ "$KEEP_DATA" -eq 1 ]; then
        echo -e "  All system files restored. data.json and credentials preserved."
    else
        echo -e "  Full clean reinstall. New config and credentials applied."
    fi
    echo ""
}


# =============================================================================
# UNINSTALL
# =============================================================================
do_uninstall() {
    echo -e "\n${BD}${C}=== nat-manager-webui — uninstall ===${N}\n"
    echo -e "  ${Y}Removes all files, services, rules, and temp data installed by this tool.${N}"
    echo -e "  ${Y}System packages (apache2, php, iptables) are NOT removed.${N}\n"
    [[ "$(ask "Proceed with uninstall?")" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

    # ── Services ───────────────────────────────────────────────────────────────
    hdr "Services"
    for svc in nat-manager-webui.service; do
        if systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc"; then
            systemctl stop    "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            ok "Stopped and disabled $svc"
        fi
    done
    rmf "$UNIT"
    systemctl daemon-reload 2>/dev/null || true

    # ── Secondary IPs — remove from bridges BEFORE deleting data.json ─────────
    hdr "Secondary IPs on bridges"
    BOUND_IPS=()
    if [ -f "$DATA" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && BOUND_IPS+=("$line")
        done < <(python3 - << 'PY'
import json
try: d=json.load(open("/var/lib/nat-manager-webui/data.json"))
except: d={}
for n in d.get("networks",[]):
    b=n.get("bridge","vmbr0"); p=str(n.get("prefix","29"))
    for ip in n.get("ips",[]):
        if ip: print(f"{b} {ip}/{p}")
PY
)
    fi
    # Also catch any secondary IPs on vmbr bridges that aren't the host IP
    while IFS= read -r line; do
        BOUND_IPS+=("$line")
    done < <(ip -o -4 addr show 2>/dev/null \
        | awk '/vmbr/ && /secondary/ {print $2, $4}' || true)
    # Deduplicate
    declare -A SEEN_IPS
    for entry in "${BOUND_IPS[@]:-}"; do
        [ -z "${entry:-}" ] && continue
        BR=$(echo "$entry" | awk '{print $1}')
        IPCIDR=$(echo "$entry" | awk '{print $2}')
        KEY="${BR}:${IPCIDR}"
        [ "${SEEN_IPS[$KEY]:-}" = "1" ] && continue
        SEEN_IPS[$KEY]=1
        if ip addr show "$BR" 2>/dev/null | grep -qw "$IPCIDR"; then
            if [[ "$(ask "Remove $IPCIDR from $BR?")" =~ ^[Yy]$ ]]; then
                ip addr del "$IPCIDR" dev "$BR" 2>/dev/null && ok "Removed $IPCIDR from $BR" || warn "Could not remove $IPCIDR"
            fi
        fi
    done
    [ ${#BOUND_IPS[@]} -eq 0 ] && info "No secondary IPs found"

    # ── Live iptables rules ────────────────────────────────────────────────────
    hdr "Live iptables NAT rules"
    DNAT_N=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c DNAT || echo 0)
    MASQ_N=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -c MASQUERADE || echo 0)
    echo -e "  PREROUTING DNAT rules   : $DNAT_N"
    echo -e "  POSTROUTING MASQUERADE  : $MASQ_N"
    warn "Flushing these chains will break port-forwarding and VM internet immediately."
    if [[ "$(ask "Flush live NAT + FORWARD iptables rules?")" =~ ^[Yy]$ ]]; then
        iptables -t nat -F PREROUTING  && ok "Flushed nat PREROUTING"
        iptables -t nat -F POSTROUTING && ok "Flushed nat POSTROUTING"
        iptables -F FORWARD            && ok "Flushed FORWARD chain"
    fi

    # ── Saved rules file ───────────────────────────────────────────────────────
    hdr "Saved iptables rules file"
    rmf "$RULES"
    rmdir /etc/iptables 2>/dev/null || true

    # ── Web files ──────────────────────────────────────────────────────────────
    hdr "Web application files"
    if present "$WEBROOT"; then
        if [[ "$(ask "Remove $WEBROOT (index.php + data.json)?")" =~ ^[Yy]$ ]]; then
            rmrf "$WEBROOT"
        fi
    else info "$WEBROOT not found"; fi

    # ── Binaries ───────────────────────────────────────────────────────────────
    hdr "Binaries"
    for f in "$NATMGR" "${NATMGR}.bak" "${NATMGR}.bak2" "${NATMGR}.bak3"; do
        rmf "$f"
    done

    # ── Sudoers ────────────────────────────────────────────────────────────────
    hdr "Sudoers"
    rmf "$SUDOERS"

    # ── Sysctl ────────────────────────────────────────────────────────────────
    hdr "Sysctl"
    rmf "$SYSCTL"

    # ── Log files ─────────────────────────────────────────────────────────────
    hdr "Log files"
    rmf "$LOG_NAT"

    # ── Temp / runtime files ───────────────────────────────────────────────────
    hdr "Temp files"
    # Rate-limit files
    RL_COUNT=$(ls /tmp/.nmrl_* 2>/dev/null | wc -l || echo 0)
    if [ "$RL_COUNT" -gt 0 ]; then
        rm -f /tmp/.nmrl_* && ok "Removed $RL_COUNT rate-limit file(s)"
    else info "No rate-limit temp files"; fi
    # Backup files created by fix scripts
    for f in "${WEBUI:-/var/www/html/nat-manager-webui/index.php}.bak" \
              /usr/local/bin/nat-mgr.bak /usr/local/bin/nat-mgr.bak2 \
              /usr/local/bin/nat-mgr.bak3; do
        rmf "$f" 2>/dev/null || true
    done
    # PHP session files (optional)
    PHP_SESS_DIR="/var/lib/php/sessions"
    if [ -d "$PHP_SESS_DIR" ]; then
        SESS_N=$(find "$PHP_SESS_DIR" -maxdepth 1 -name "sess_*" 2>/dev/null | wc -l || echo 0)
        if [ "$SESS_N" -gt 0 ]; then
            warn "$SESS_N PHP session file(s) found (may belong to other PHP apps too)"
            if [[ "$(ask "Remove ALL PHP session files?")" =~ ^[Yy]$ ]]; then
                find "$PHP_SESS_DIR" -maxdepth 1 -name "sess_*" -delete
                ok "Removed $SESS_N session file(s)"
            fi
        fi
    fi

    echo ""
    echo -e "${BD}${C}==== Uninstall complete ====${N}"
    echo -e "  System packages (apache2, php, iptables) were not removed."
    echo ""
}


# =============================================================================
# CLEANUP — remove ALL traces from ALL historical versions
# =============================================================================
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  MAINTAINER NOTE: when releasing a new version, add ANY new             │
# │  files/dirs/services/configs that version introduces to this function.  │
# │  cleanup must always cover the entire history of every version.         │
# └─────────────────────────────────────────────────────────────────────────┘
#
# Version artifact history:
#   port-8080 era  : /var/www/html/router/, router.conf, ipt, ipt-save,
#                    .router_passwd, Listen 8080, /etc/network/interfaces lines
#   proxmox-webui  : /var/www/html/proxmox-webui/, proxmox-webui.conf,
#                    pwui-* helpers, ttyd, proxmox-webui-ttyd.service
#   nat-mgr-webui  : /var/www/html/nat-manager-webui/, nat-mgr, sudoers,
#     v1.x           data.json in webroot, /etc/apache2/conf-*/nat-manager-webui.conf
#     v2.x           data.php in webroot, /var/lib/nat-manager-webui/
#   all versions   : iptables rules, sysctl, systemd unit, logs, tmp files
do_cleanup() {
    echo -e "\n${BD}${R}=== nat-manager-webui — cleanup ===${N}\n"
    echo -e "  ${Y}Removes ALL traces of nat-manager-webui (all versions) from this server.${N}"
    echo -e "  ${Y}This includes web files, binaries, services, iptables rules,${N}"
    echo -e "  ${Y}secondary IPs on bridges, logs, and temp files.${N}"
    echo -e "  ${Y}System packages (apache2, php, iptables) are NOT removed.${N}"
    echo ""
    read -rp "  Type YES to confirm full cleanup: " CONF
    [ "$CONF" = "YES" ] || { echo "  Cancelled."; exit 0; }
    echo ""

    # ── Services (all versions) ───────────────────────────────────────────────
    hdr "Services"
    for svc in nat-manager-webui.service proxmox-webui-ttyd.service; do
        if systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc" ||            [ -f "/etc/systemd/system/$svc" ]; then
            systemctl stop    "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            rmf "/etc/systemd/system/$svc"
            ok "Removed $svc"
        fi
    done
    systemctl daemon-reload 2>/dev/null || true

    # ── Secondary IPs on bridges — remove BEFORE deleting config files ────────
    hdr "Secondary IPs on bridges"
    _remove_secondary_ips() {
        local removed=0
        # Try to read from any known data file location
        for datafile in             "/var/www/html/nat-manager-webui/data.php"             "/var/www/html/nat-manager-webui/data.json"             "/var/lib/nat-manager-webui/data.json"; do
            [ -f "$datafile" ] || continue
            python3 - "$datafile" << 'PY'
import json, sys, re
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception as e:
    sys.exit(0)
for n in d.get("networks", []):
    b = n.get("bridge","vmbr0"); p = str(n.get("prefix","29"))
    for ip in n.get("ips", []):
        if ip: print(f"{b}|{ip}/{p}")
PY
        break
        done
    }
    while IFS='|' read -r BR IPCIDR; do
        [ -z "$BR" ] && continue
        if ip addr show "$BR" 2>/dev/null | grep -qw "$IPCIDR"; then
            ip addr del "$IPCIDR" dev "$BR" 2>/dev/null                 && ok "Removed $IPCIDR from $BR"                 || warn "Could not remove $IPCIDR from $BR"
        fi
    done < <(_remove_secondary_ips)
    # Also catch any remaining secondary IPs on vmbr bridges
    ip -o -4 addr show 2>/dev/null | awk '/vmbr/ && /secondary/ {print $2, $4}' |     while read -r BR IPCIDR; do
        ip addr del "$IPCIDR" dev "$BR" 2>/dev/null             && ok "Removed stale $IPCIDR from $BR" || true
    done

    # ── Live iptables ─────────────────────────────────────────────────────────
    hdr "Live iptables rules"
    iptables -t nat -F PREROUTING  2>/dev/null && ok "Flushed nat PREROUTING"  || true
    iptables -t nat -F POSTROUTING 2>/dev/null && ok "Flushed nat POSTROUTING" || true
    iptables -F FORWARD            2>/dev/null && ok "Flushed FORWARD chain"   || true

    # ── Web roots (all versions) ──────────────────────────────────────────────
    hdr "Web application files"
    for d in         "/var/www/html/nat-manager-webui"         "/var/www/html/proxmox-webui"         "/var/www/html/router"; do
        rmrf "$d"
    done
    # v2.x data directory (outside webroot)
    rmrf "/var/lib/nat-manager-webui"

    # ── Apache configuration (all versions) ───────────────────────────────────
    hdr "Apache configuration"
    for f in         "/etc/apache2/sites-available/nat-manager-webui.conf"         "/etc/apache2/sites-enabled/nat-manager-webui.conf"         "/etc/apache2/sites-available/proxmox-webui.conf"         "/etc/apache2/sites-enabled/proxmox-webui.conf"         "/etc/apache2/sites-available/router.conf"         "/etc/apache2/sites-enabled/router.conf"         "/etc/apache2/conf-available/nat-manager-webui.conf"         "/etc/apache2/conf-enabled/nat-manager-webui.conf"         "/etc/apache2/.router_passwd"; do
        rmf "$f"
    done
    # Remove Listen 8080 from ports.conf if present
    if grep -q "Listen 8080" /etc/apache2/ports.conf 2>/dev/null; then
        sed -i '/Listen 8080/d' /etc/apache2/ports.conf
        ok "Removed 'Listen 8080' from ports.conf"
    fi
    # Re-enable default site if it was disabled
    if [ -f /etc/apache2/sites-available/000-default.conf ] &&        [ ! -e /etc/apache2/sites-enabled/000-default.conf ]; then
        a2ensite 000-default.conf >/dev/null 2>&1 && ok "Re-enabled 000-default.conf"
    fi
    systemctl is-active apache2 >/dev/null 2>&1 &&         systemctl reload apache2 2>/dev/null && ok "Apache reloaded"

    # ── Binaries (all versions) ───────────────────────────────────────────────
    hdr "Binaries"
    for f in         "/usr/local/bin/nat-mgr"         "/usr/local/bin/nat-mgr.bak"         "/usr/local/bin/nat-mgr.bak2"         "/usr/local/bin/nat-mgr.bak3"         "/usr/local/bin/nat-sync-ips"         "/usr/local/bin/ipt"         "/usr/local/bin/ipt-save"         "/usr/local/bin/pwui-update-helper"         "/usr/local/bin/pwui-session-check"         "/usr/local/bin/pwui-helper"         "/usr/local/bin/pwui-helper-tasks.sh"         "/usr/local/bin/pwui-helper.sh"         "/usr/local/bin/ttyd"; do
        rmf "$f"
    done

    # ── Sudoers ───────────────────────────────────────────────────────────────
    hdr "Sudoers"
    rmf "/etc/sudoers.d/nat-manager-webui"

    # ── Sysctl ────────────────────────────────────────────────────────────────
    hdr "Sysctl"
    rmf "/etc/sysctl.d/99-nat-manager.conf"
    rmf "/etc/sysctl.d/99-ip-forward.conf"

    # ── Saved iptables rules ──────────────────────────────────────────────────
    hdr "Saved iptables rules"
    rmf "/etc/iptables/rules.v4"
    rmdir /etc/iptables 2>/dev/null || true

    # ── /etc/network/interfaces ───────────────────────────────────────────────
    hdr "/etc/network/interfaces"
    if grep -qE 'iptables-restore|nat-sync-ips|# nat-manager' /etc/network/interfaces 2>/dev/null; then
        cp /etc/network/interfaces /etc/network/interfaces.bak
        sed -i '/pre-up iptables-restore/d'          /etc/network/interfaces
        sed -i '/post-up.*nat-sync-ips/d'            /etc/network/interfaces
        sed -i '/post-up ip addr add.*# nat-manager/d' /etc/network/interfaces
        sed -i '/pre-up iptables-restore.*rules\.v4/d' /etc/network/interfaces
        ok "Cleaned /etc/network/interfaces (backup: /etc/network/interfaces.bak)"
    else
        skip "/etc/network/interfaces — no project entries found"
    fi

    # ── Logs ──────────────────────────────────────────────────────────────────
    hdr "Log files"
    rmf "/var/log/nat-manager.log"
    rmf "/var/log/nat-sync-ips.log"

    # ── Temp / runtime files ──────────────────────────────────────────────────
    hdr "Temp files"
    rm -f /tmp/.nmrl_* 2>/dev/null && ok "Removed rate-limit temp files" || true
    rm -f /tmp/_nmwrite.py 2>/dev/null || true
    # Backup files left by fix scripts
    rm -f /usr/local/bin/nat-mgr.bak*           /var/www/html/nat-manager-webui/index.php.bak           /var/www/html/nat-manager-webui/data.json.bak           /var/www/html/nat-manager-webui/data.php.bak 2>/dev/null || true
    ok "Temp and backup files removed"

    echo ""
    echo -e "${BD}${G}==== Cleanup complete ====${N}"
    echo -e "  All nat-manager-webui artifacts removed (all versions)."
    echo -e "  System packages (apache2, php, iptables) were not removed."
    echo -e "  Run ${BD}bash nat-manager-webui.sh install${N} to set up fresh."
    echo ""
}
# =============================================================================
# DISPATCH
# =============================================================================
if [ $# -eq 0 ]; then
    clear
    echo -e "${BD}${C}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║    nat-manager-webui  v${VERSION}          ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${N}"
    echo -e "  ${BD}1)${N} Install   — fresh install (interactive setup)"
    echo -e "  ${BD}2)${N} Update    — update app files, keep config & credentials"
    echo -e "  ${BD}3)${N} Reinstall — full re-setup, preserve or replace config"
    echo -e "  ${BD}4)${N} Uninstall — interactive removal (asks per category)"
    echo -e "  ${BD}5)${N} Cleanup   — remove ALL traces from ALL historical versions"
    echo ""
    while true; do
        read -rp "  Choose [1-5]: " CHOICE
        case "$CHOICE" in
            1) MODE="install"   ; break ;;
            2) MODE="update"    ; break ;;
            3) MODE="reinstall" ; break ;;
            4) MODE="uninstall" ; break ;;
            5) MODE="cleanup"   ; break ;;
            *) echo -e "  ${Y}Please enter 1, 2, 3, 4 or 5${N}" ;;
        esac
    done
    echo ""
else
    MODE="${1}"
fi

case "$MODE" in
    install)   do_install ;;
    update)    do_update ;;
    reinstall) do_reinstall ;;
    uninstall) do_uninstall ;;
    cleanup)   do_cleanup ;;
    *) echo -e "\n  Usage: $0 {install|update|reinstall|uninstall|cleanup}\n"; exit 1 ;;
esac