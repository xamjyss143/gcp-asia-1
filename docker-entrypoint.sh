#!/bin/sh
set -eu

NGINX_CONF="/etc/nginx/nginx.conf"
API_URL="https://vpnhub.cloud/xjvpn/api/server/register-gcp"
API_URL2="https://pussyvpn.com/xjvpn/server/register-gcp"

if [ -z "${GCP_HOST:-}" ]; then
  echo "ERROR: GCP_HOST is not set"
  exit 1
fi

echo "Using GCP_HOST=$GCP_HOST"

response_file=$(mktemp)
trap 'rm -f "$response_file"' EXIT INT TERM

register_server() {
  api_url="$1"
  payload="$2"

  : > "$response_file"

  http_code=$(curl -sS \
    -o "$response_file" \
    -w '%{http_code}' \
    -X POST "$api_url" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$payload")

  response_body=$(cat "$response_file")

  if [ -n "$response_body" ]; then
    printf '%s\n' "$response_body"
  fi

  REGISTER_HTTP_CODE="$http_code"
  REGISTER_RESPONSE="$response_body"
}

awk '
/location \/[a-z0-9]+ \{/ {
    path=$2
}
/proxy_pass http:\/\/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:700;/ {
    gsub(";", "", $2)
    gsub("http://", "", $2)
    split($2, parts, ":")
    ip=parts[1]
    print path "|" ip
}
' "$NGINX_CONF" | while IFS="|" read -r gcp_path ip; do
    code=$(printf '%s' "$gcp_path" | sed 's#^/##')

    gcp_xray_path="/vless_${code}"
    gcp_vmess_path="/vmess_${code}"
    gcp_trojan_path="/trojan-ws_${code}"

    payload=$(printf '{
      "ip": "%s",
      "gcp_host": "%s",
      "gcp_path": "%s",
      "gcp_xray_path": "%s",
      "gcp_vmess_path": "%s",
      "gcp_trojan_path": "%s"
    }' \
      "$ip" \
      "$GCP_HOST" \
      "$gcp_path" \
      "$gcp_xray_path" \
      "$gcp_vmess_path" \
      "$gcp_trojan_path")

    echo "Checking API 1 for $ip"

    register_server "$API_URL" "$payload"

    case "$REGISTER_HTTP_CODE" in
      2??)
        if printf '%s' "$REGISTER_RESPONSE" |
          grep -Eqi 'not found|server_not_found|does not exist'; then
          api1_missing=true
        else
          api1_missing=false
          echo "Registered $ip using API 1"
        fi
        ;;

      404)
        api1_missing=true
        ;;

      *)
        echo "ERROR: API 1 returned HTTP $REGISTER_HTTP_CODE for $ip"
        exit 1
        ;;
    esac

    if [ "$api1_missing" = true ]; then
      echo "$ip was not found on API 1. Trying API 2."

      register_server "$API_URL2" "$payload"

      case "$REGISTER_HTTP_CODE" in
        2??)
          echo "Registered $ip using API 2"
          ;;

        *)
          echo "ERROR: API 2 returned HTTP $REGISTER_HTTP_CODE for $ip"
          exit 1
          ;;
      esac
    fi

    echo ""
done

exec nginx -g 'daemon off;'
