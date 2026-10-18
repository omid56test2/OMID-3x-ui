#!/bin/sh

# Falix and other restricted container hosts may run this image as a non-root
# user. In that mode, keep all mutable panel data in the writable home folder,
# seed the runtime binary folder from the image, and disable host-level
# fail2ban (it needs root and NET_ADMIN/iptables access).
if [ "$(id -u)" -ne 0 ]; then
    if [ -z "${OMID_DATA_DIR:-}" ]; then
        if [ -n "${HOME:-}" ] && [ -d "$HOME" ] && [ -w "$HOME" ]; then
            OMID_DATA_DIR="$HOME/omid-data"
        elif [ -d /home/container ] && [ -w /home/container ]; then
            OMID_DATA_DIR="/home/container/omid-data"
        else
            echo "ERROR: no writable home directory found; set OMID_DATA_DIR to a writable persistent path." >&2
            exit 1
        fi
    fi
    export XUI_DB_FOLDER="${XUI_DB_FOLDER:-$OMID_DATA_DIR}"
    export XUI_LOG_FOLDER="${XUI_LOG_FOLDER:-$OMID_DATA_DIR/logs}"
    export XUI_BIN_FOLDER="${XUI_BIN_FOLDER:-$OMID_DATA_DIR/bin}"
    export XUI_NODE_TOKEN_KEY_FILE="${XUI_NODE_TOKEN_KEY_FILE:-$OMID_DATA_DIR/node_token_key.json}"
    export XUI_ENABLE_FAIL2BAN="false"

    for writable_dir in "$XUI_DB_FOLDER" "$XUI_LOG_FOLDER" "$XUI_BIN_FOLDER"; do
        if ! mkdir -p "$writable_dir" || [ ! -w "$writable_dir" ]; then
            echo "ERROR: required writable directory is unavailable: $writable_dir" >&2
            exit 1
        fi
    done

    # The image ships Xray, mtg and geodata in /app/bin, which is read-only
    # under restricted hosts. Copy each asset once so updates to the persistent
    # copy are not overwritten on every restart.
    if [ -d /app/bin ]; then
        for source_file in /app/bin/*; do
            [ -f "$source_file" ] || continue
            target_file="$XUI_BIN_FOLDER/${source_file##*/}"
            if [ ! -e "$target_file" ]; then
                if ! cp "$source_file" "$target_file"; then
                    echo "ERROR: failed to copy runtime asset: $source_file" >&2
                    exit 1
                fi
            fi
        done
    fi

    for runtime_binary in "$XUI_BIN_FOLDER"/xray-* "$XUI_BIN_FOLDER"/mtg-*; do
        [ -f "$runtime_binary" ] || continue
        chmod u+x "$runtime_binary" 2>/dev/null || true
    done
fi

# Start fail2ban with the 3x-ipl jail. It is automatically disabled in
# non-root restricted containers because it requires privileged firewall access.
if [ "${XUI_ENABLE_FAIL2BAN:-false}" = "true" ]; then
    LOG_FOLDER="${XUI_LOG_FOLDER:-/var/log/x-ui}"
    mkdir -p "$LOG_FOLDER"
    touch "$LOG_FOLDER/3xipl.log" "$LOG_FOLDER/3xipl-banned.log"

    mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d /etc/fail2ban/action.d

    cat > /etc/fail2ban/jail.d/3x-ipl.conf << EOF
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=$LOG_FOLDER/3xipl.log
maxretry=1
findtime=32
bantime=30m
EOF

    cat > /etc/fail2ban/filter.d/3x-ipl.conf << 'EOF'
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

    # Ports to exempt from the ban so an over-limit proxy client can never lock
    # the administrator out of SSH or the panel. The ban still covers every other
    # TCP port (including all Xray inbounds), so IP-limit keeps working for inbounds
    # added later without regenerating these files.
    SSH_PORTS=$(grep -oE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | grep -oE '[0-9]+' | paste -sd, -)
    [ -z "$SSH_PORTS" ] && SSH_PORTS="22"
    PANEL_PORT=$(/app/x-ui setting -show true 2>/dev/null | grep -Eo 'port: .+' | awk '{print $2}')
    # Honor the runtime override used for the panel backend behind Nginx.
    [ -n "${XUI_PORT:-}" ] && PANEL_PORT="$XUI_PORT"
    EXEMPT_PORTS="$SSH_PORTS"
    [ -n "$PANEL_PORT" ] && EXEMPT_PORTS="$EXEMPT_PORTS,$PANEL_PORT"
    # The public app port is handled by Nginx; keep it reachable when IP-limit bans apply.
    EXEMPT_PORTS="$EXEMPT_PORTS,2053"

    cat > /etc/fail2ban/action.d/3x-ipl.conf << EOF
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -j f2b-<name>

actionstop = <iptables> -D <chain> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
            <iptables> -I f2b-<name> 1 -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> $LOG_FOLDER/3xipl-banned.log

actionunban = <iptables> -D f2b-<name> -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
              <iptables> -D f2b-<name> -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> $LOG_FOLDER/3xipl-banned.log

[Init]
name = default
chain = INPUT
exemptports = $EXEMPT_PORTS
EOF

    fail2ban-client -x start
fi

# Certificate auto-renewal: acme.sh (installed by the panel's SSL menu) relies
# on a root crontab entry, but the crontab is lost when the container is
# recreated and crond was never started. Re-register the job and run crond so
# renewals actually fire; mount /root/.acme.sh as a volume to keep acme state.
if [ "$(id -u)" -eq 0 ] && [ -f /root/.acme.sh/acme.sh ]; then
    /root/.acme.sh/acme.sh --install-cronjob >/dev/null 2>&1
    crond
fi

# Run the panel backend and Nginx under supervisord. Nginx owns the single
# application port exposed by Lucity and proxies panel, subscription and WS paths.
exec /usr/bin/supervisord -n -c /etc/supervisord.conf
