#!/bin/sh
# Generates /etc/nginx/omid-routes.conf from OMID_ROUTES at container start.
#   OMID_ROUTES="/my-secret-path=8081,/api/v2/stream=8082"
# Each entry maps a custom public path (on port 2053) to an inbound on 127.0.0.1:PORT
# (PORT must be 8081..8090). The inbound's path in 3X-UI must equal the same path.
# Invalid entries are skipped with a warning; nginx always starts.
OUT="${OMID_ROUTES_OUT:-/etc/nginx/omid-routes.conf}"
: > "$OUT"
[ -z "${OMID_ROUTES:-}" ] && exit 0

echo "$OMID_ROUTES" | tr ',' '\n' | while IFS= read -r entry; do
    entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$entry" ] && continue
    path="${entry%=*}"
    port="${entry##*=}"
    path="${path%/}"
    if ! echo "$path" | grep -Eq '^/[A-Za-z0-9._~/-]+$' || echo "$path" | grep -q '\.\.' || echo "$path" | grep -q '//'; then
        echo "omid-routes: skipped '$entry' (invalid path)" >&2; continue
    fi
    if ! echo "$port" | grep -Eq '^(808[1-9]|8090)$'; then
        echo "omid-routes: skipped '$entry' (port must be 8081-8090)" >&2; continue
    fi
    seg=$(echo "$path" | cut -d/ -f2 | tr 'A-Z' 'a-z')
    case "$seg" in
        sub|json|clash|mihomo|clash-legacy|healthz)
            echo "omid-routes: skipped '$entry' (reserved path)" >&2; continue ;;
    esac
    cat >> "$OUT" << CONF
location = $path { proxy_pass http://127.0.0.1:$port; include /etc/nginx/omid-proxy-common.conf; }
location ^~ $path/ { proxy_pass http://127.0.0.1:$port; include /etc/nginx/omid-proxy-common.conf; }
CONF
    echo "omid-routes: $path -> 127.0.0.1:$port" >&2
done
exit 0
