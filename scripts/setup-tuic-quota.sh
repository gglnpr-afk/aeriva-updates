#!/bin/bash
# setup-tuic-quota.sh — one-time upgrade of the plain TUIC install
# (from setup-tuic.sh) to the quota-managed kit:
#   * custom sing-box binary built with the v2ray_api stats service
#     (the stock binary cannot do per-user stats at all)
#   * user registry /root/tuic-users.txt — existing users are seeded
#     from the live config, so the current TUIC-JP-OWN link keeps working
#   * add-tuic <name> [GB] [days] — mint customer keys (SS quota kit UX)
#   * gs-tuic-guard — cron every 5 min, removes users at quota/expiry,
#     writes /root/tuic-quota-status.txt
# Downloads ONLY the two binaries below; every script is embedded.
# Safe to re-run: the registry is never reseeded once it exists.
set -e

BIN_URL="https://github.com/gglnpr-afk/aeriva-updates/releases/download/tuic-kit-1/sing-box-quota.gz"
QUERY_URL="https://github.com/gglnpr-afk/aeriva-updates/releases/download/tuic-kit-1/gs-stats-query.gz"
SB_DIR="/usr/local/etc/sing-box"
CONFIG="$SB_DIR/config.json"
REGISTRY="/root/tuic-users.txt"

echo "=== TUIC quota kit setup ==="

# 0. Sanity: plain TUIC install must exist.
[ -f "$CONFIG" ] || { echo "!! $CONFIG not found — run setup-tuic.sh first. Aborting."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "!! python3 is required. Aborting."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "!! curl is required. Aborting."; exit 1; }

# 1. Binaries (stock sing-box is backed up, not deleted).
echo "-- downloading quota binaries..."
cd /tmp
curl -fsSL -o sing-box-quota.gz "$BIN_URL"
curl -fsSL -o gs-stats-query.gz "$QUERY_URL"
gzip -dc sing-box-quota.gz > sing-box-quota.bin
gzip -dc gs-stats-query.gz > gs-stats-query.bin
chmod 755 sing-box-quota.bin gs-stats-query.bin
if [ -x /usr/local/bin/sing-box ] && [ ! -f /usr/local/bin/sing-box.stock.bak ]; then
  cp /usr/local/bin/sing-box /usr/local/bin/sing-box.stock.bak
  echo "-- stock binary backed up to /usr/local/bin/sing-box.stock.bak"
fi
install -m 0755 sing-box-quota.bin /usr/local/bin/sing-box
install -m 0755 gs-stats-query.bin /usr/local/bin/gs-stats-query
rm -f sing-box-quota.gz gs-stats-query.gz sing-box-quota.bin gs-stats-query.bin
/usr/local/bin/sing-box version | head -2

# 2. Seed the registry from the CURRENT config (existing users keep
#    working: same uuid/password, quota 0 = unlimited, expiry 0 = none).
if [ ! -f "$REGISTRY" ]; then
  echo "-- seeding registry from current config..."
  python3 - "$CONFIG" "$REGISTRY" <<'SEED_EOF'
import json
import sys

config_path, registry_path = sys.argv[1], sys.argv[2]
with open(config_path) as f:
    config = json.load(f)
users = []
for inbound in config.get("inbounds", []):
    if inbound.get("type") == "tuic":
        users = inbound.get("users", [])
        break
with open(registry_path, "w") as f:
    f.write("# name uuid password quotaGB expiryEpoch  (0 = unlimited / none)\n")
    for u in users:
        f.write(f"{u['name']} {u['uuid']} {u['password']} 0 0\n")
print(f"seeded {len(users)} existing user(s)")
SEED_EOF
  chmod 600 "$REGISTRY"
else
  echo "-- registry already exists, keeping it"
fi

# 3. Helper scripts (embedded, self-contained).
cat > /usr/local/bin/tuic-render.py <<'TUIC_RENDER_EOF'
#!/usr/bin/env python3
"""tuic-render.py — render the sing-box config from the TUIC user registry.

Registry: /root/tuic-users.txt, one user per line:
    name uuid password quotaGB expiryEpoch
(quotaGB 0 = unlimited, expiryEpoch 0 = no expiry; '#' lines are comments)

Output: /usr/local/etc/sing-box/config.json — same TUIC inbound shape as
setup-tuic.sh, plus experimental.v2ray_api per-user traffic stats on
127.0.0.1:10087 so gs-tuic-guard can meter usage.
"""
import json
import sys

REGISTRY = "/root/tuic-users.txt"
CONFIG = "/usr/local/etc/sing-box/config.json"
SB_DIR = "/usr/local/etc/sing-box"
PORT = 443
STATS_ADDR = "127.0.0.1:10087"


def read_registry(path=REGISTRY):
    users = []
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 5:
            print(f"tuic-render: skipping malformed registry line: {line!r}", file=sys.stderr)
            continue
        name, uuid, password, quota, expiry = parts
        users.append({
            "name": name,
            "uuid": uuid,
            "password": password,
            "quota_gb": float(quota),
            "expiry": int(expiry),
        })
    return users


def build_config(users):
    sb_users = [{"name": u["name"], "uuid": u["uuid"], "password": u["password"]} for u in users]
    return {
        "log": {"level": "info", "timestamp": True},
        "inbounds": [
            {
                "type": "tuic",
                "tag": "tuic-in",
                "listen": "::",
                "listen_port": PORT,
                "users": sb_users,
                "congestion_control": "bbr",
                "auth_timeout": "3s",
                "zero_rtt_handshake": False,
                "heartbeat": "10s",
                "tls": {
                    "enabled": True,
                    "alpn": ["h3"],
                    "certificate_path": f"{SB_DIR}/cert.pem",
                    "key_path": f"{SB_DIR}/key.pem",
                },
            }
        ],
        "outbounds": [{"type": "direct", "tag": "direct"}],
        "experimental": {
            "v2ray_api": {
                "listen": STATS_ADDR,
                "stats": {
                    "enabled": True,
                    "inbounds": ["tuic-in"],
                    "users": [u["name"] for u in users],
                },
            }
        },
    }


def main():
    users = read_registry()
    config = build_config(users)
    with open(CONFIG, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    print(f"tuic-render: wrote {CONFIG} with {len(users)} user(s)")


if __name__ == "__main__":
    main()
TUIC_RENDER_EOF
cat > /usr/local/bin/add-tuic <<'TUIC_ADD_EOF'
#!/bin/bash
# add-tuic <name> [quotaGB=100] [days=30]
# Mint one TUIC user into the registry, re-render the sing-box config and
# restart gs-tuic. quotaGB 0 / days 0 = unlimited. Prints the customer link.
# On any failure after the registry append, the row is rolled back.
set -u

REGISTRY="/root/tuic-users.txt"
DOMAIN="JP.mobileking.vip"
PORT="443"

NAME="${1:-}"
QUOTA="${2:-100}"
DAYS="${3:-30}"

if [ -z "$NAME" ]; then
  echo "usage: add-tuic <name> [quotaGB=100] [days=30]" >&2
  exit 2
fi
if ! echo "$NAME" | grep -qE '^[a-zA-Z0-9_-]+$'; then
  echo "!! name must match [a-zA-Z0-9_-]+" >&2
  exit 2
fi
if ! echo "$QUOTA" | grep -qE '^[0-9]+([.][0-9]+)?$'; then
  echo "!! quotaGB must be a number (0 = unlimited)" >&2
  exit 2
fi
if ! echo "$DAYS" | grep -qE '^[0-9]+$'; then
  echo "!! days must be a whole number (0 = no expiry)" >&2
  exit 2
fi

touch "$REGISTRY"
if awk -v n="$NAME" '$1 == n { found=1 } END { exit !found }' "$REGISTRY"; then
  echo "!! user '$NAME' already exists — refusing duplicate" >&2
  exit 1
fi

UUID=$(/usr/local/bin/sing-box generate uuid)
PASS=$(openssl rand -hex 12)
if [ "$DAYS" -gt 0 ]; then
  EXPIRY=$(( $(date +%s) + DAYS * 86400 ))
else
  EXPIRY=0
fi

cp "$REGISTRY" "$REGISTRY.bak"
echo "$NAME $UUID $PASS $QUOTA $EXPIRY" >> "$REGISTRY"

rollback() {
  echo "!! failed — rolling back registry" >&2
  mv "$REGISTRY.bak" "$REGISTRY"
  python3 /usr/local/bin/tuic-render.py >/dev/null 2>&1
  /usr/local/bin/sing-box check -c /usr/local/etc/sing-box/config.json >/dev/null 2>&1 && \
    systemctl restart gs-tuic >/dev/null 2>&1
  exit 1
}

python3 /usr/local/bin/tuic-render.py || rollback
/usr/local/bin/sing-box check -c /usr/local/etc/sing-box/config.json || rollback
systemctl restart gs-tuic || rollback
sleep 1
systemctl is-active --quiet gs-tuic || rollback
rm -f "$REGISTRY.bak"

LINK="tuic://${UUID}:${PASS}@${DOMAIN}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${DOMAIN}&allow_insecure=1#TUIC-${NAME}"
echo ""
echo "=== TUIC LINK for ${NAME} (quota ${QUOTA} GB, ${DAYS} days) ==="
echo "$LINK"
echo "=============================================================="
TUIC_ADD_EOF
cat > /usr/local/bin/gs-tuic-guard <<'TUIC_GUARD_EOF'
#!/bin/bash
# gs-tuic-guard — TUIC quota/expiry enforcer (run from cron every 5 min).
#
# Reads per-user counters from sing-box's v2ray_api stats
# (user>>><name>>>>traffic>>>uplink/downlink) via gs-stats-query and
# accumulates them in /var/lib/gs-tuic/usage.tsv.
#
# NOTE on accounting: the sing-box counters reset to zero whenever the
# service restarts (add-tuic, removals, crashes). The guard accumulates
# deltas every 5 minutes, so at most ~5 minutes of traffic around a
# restart can go uncounted. Deltas: cur-last when cur >= last, else cur
# (counter was reset). A counter seen for the first time only sets the
# baseline — this always errs in the customer's favour.
#
# A user is removed (registry row deleted, config re-rendered, service
# restarted) when accumulated bytes >= quota OR now >= expiry.
# Unlimited users (quota 0 / expiry 0) are tracked but never removed.
# Always rewrites /root/tuic-quota-status.txt. Quiet when nothing happens.
set -u

REGISTRY="/root/tuic-users.txt"
STATE_DIR="/var/lib/gs-tuic"
USAGE="$STATE_DIR/usage.tsv"
LAST="$STATE_DIR/last.tsv"
STATUS="/root/tuic-quota-status.txt"
CONFIG="/usr/local/etc/sing-box/config.json"
GIB=1073741824

mkdir -p "$STATE_DIR"
touch "$USAGE" "$LAST" "$REGISTRY"

RAW=$(mktemp)
trap 'rm -f "$RAW"' EXIT
/usr/local/bin/gs-stats-query -addr 127.0.0.1:10087 > "$RAW" 2>/dev/null || : > "$RAW"

# --- delta accumulation -------------------------------------------------
python3 - "$USAGE" "$LAST" "$RAW" <<'PYEOF'
import sys

usage_path, last_path, raw_path = sys.argv[1], sys.argv[2], sys.argv[3]

def load_tsv(path):
    data = {}
    try:
        with open(path) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 2:
                    try:
                        data[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return data

usage = load_tsv(usage_path)
last = load_tsv(last_path)
new_last = dict(last)

with open(raw_path) as f:
    for line in f:
        parts = line.split()
        if len(parts) != 2:
            continue
        cname = parts[0]
        try:
            value = int(parts[1])
        except ValueError:
            continue
        fields = cname.split(">>>")
        if len(fields) != 4 or fields[0] != "user" or fields[2] != "traffic":
            continue
        user = fields[1]
        prev = last.get(cname)
        if prev is None:
            delta = 0  # first sighting: baseline only
        elif value >= prev:
            delta = value - prev
        else:
            delta = value  # counter reset by a service restart
        if delta:
            usage[user] = usage.get(user, 0) + delta
        new_last[cname] = value

with open(usage_path, "w") as f:
    for key in sorted(usage):
        f.write(f"{key}\t{usage[key]}\n")
with open(last_path, "w") as f:
    for key in sorted(new_last):
        f.write(f"{key}\t{new_last[key]}\n")
PYEOF

# --- quota / expiry enforcement ----------------------------------------
NOW=$(date +%s)
CHANGED=0
while read -r NAME UUID PASS QUOTA EXPIRY _rest; do
  case "$NAME" in ''|'#'*) continue ;; esac
  USED=$(awk -F'\t' -v n="$NAME" '$1 == n { print $2 }' "$USAGE")
  USED=${USED:-0}
  REMOVE=""
  if [ "$EXPIRY" != "0" ] && [ "$NOW" -ge "$EXPIRY" ]; then
    REMOVE="expired"
  fi
  # quota may be decimal GB; compare in bytes via awk
  if [ -z "$REMOVE" ] && awk -v q="$QUOTA" 'BEGIN { exit !(q > 0) }'; then
    if awk -v u="$USED" -v q="$QUOTA" -v g="$GIB" 'BEGIN { exit !(u >= q * g) }'; then
      REMOVE="quota reached"
    fi
  fi
  if [ -n "$REMOVE" ]; then
    echo "$(date '+%F %T') gs-tuic-guard: removing user '$NAME' ($REMOVE, used $USED bytes)"
    grep -v -E "^${NAME}[[:space:]]" "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
    # purge accumulated state so a future re-mint of the same name starts clean
    sed -i "/^${NAME}\t/d" "$USAGE"
    sed -i "/^user>>>${NAME}>>>/d" "$LAST"
    CHANGED=1
  fi
done < "$REGISTRY"

if [ "$CHANGED" = "1" ]; then
  python3 /usr/local/bin/tuic-render.py >/dev/null
  if /usr/local/bin/sing-box check -c "$CONFIG" >/dev/null 2>&1; then
    systemctl restart gs-tuic >/dev/null 2>&1
  else
    echo "$(date '+%F %T') gs-tuic-guard: rendered config failed check — NOT restarting" >&2
  fi
fi

# --- status file ---------------------------------------------------------
{
  echo "# TUIC quota status — $(date '+%F %T')"
  while read -r NAME UUID PASS QUOTA EXPIRY _rest; do
    case "$NAME" in ''|'#'*) continue ;; esac
    USED=$(awk -F'\t' -v n="$NAME" '$1 == n { print $2 }' "$USAGE")
    USED=${USED:-0}
    USED_GB=$(awk -v u="$USED" -v g="$GIB" 'BEGIN { printf "%.2f", u / g }')
    if awk -v q="$QUOTA" 'BEGIN { exit !(q > 0) }'; then
      QUOTA_STR="${QUOTA} GB"
    else
      QUOTA_STR="unlimited"
    fi
    if [ "$EXPIRY" != "0" ]; then
      EXP_STR=$(date -d "@$EXPIRY" '+%F')
    else
      EXP_STR="-"
    fi
    echo "${NAME}  used ${USED_GB} GB / ${QUOTA_STR}  (expires ${EXP_STR})"
  done < "$REGISTRY"
} > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"

exit 0
TUIC_GUARD_EOF
chmod 755 /usr/local/bin/tuic-render.py /usr/local/bin/add-tuic /usr/local/bin/gs-tuic-guard

# 4. Render + check + restart with the stats-enabled binary.
python3 /usr/local/bin/tuic-render.py
/usr/local/bin/sing-box check -c "$CONFIG"
echo "-- config OK"
systemctl daemon-reload
systemctl restart gs-tuic
sleep 1
systemctl is-active gs-tuic

# 5. The stats API must answer (guard depends on it).
echo "-- checking stats API..."
OK=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if /usr/local/bin/gs-stats-query -addr 127.0.0.1:10087 >/dev/null 2>&1; then OK=1; break; fi
  sleep 1
done
if [ "$OK" != "1" ]; then
  echo "!! stats API not answering — inspect: journalctl -u gs-tuic -n 30"
  exit 1
fi
echo "-- stats API OK"

# 6. Cron guard + first status snapshot.
cat > /etc/cron.d/gs-tuic-guard <<'CRON_EOF'
*/5 * * * * root /usr/local/bin/gs-tuic-guard >>/var/log/gs-tuic-guard.log 2>&1
CRON_EOF
chmod 644 /etc/cron.d/gs-tuic-guard
/usr/local/bin/gs-tuic-guard || true

echo ""
echo "=== TUIC quota kit installed ==="
cat /root/tuic-quota-status.txt
echo "================================"
echo "Mint a customer:  add-tuic <name> [GB] [days]    e.g. add-tuic aung 100 30"
echo "Usage status:     cat /root/tuic-quota-status.txt"
echo "Your own TUIC-JP-OWN link is unchanged — /root/my-tuic.txt still works."
