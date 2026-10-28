#!/bin/sh
set -eu

NGINX_CONF="/etc/nginx/nginx.conf"
API_URL="https://xjdev.net/xjvpn/server/register-gcp"
API_URL2="https://pussyvpn.com/xjvpn/server/register-gcp"

if [ -z "${GCP_HOST:-}" ]; then
  echo "ERROR: GCP_HOST is not set"
  exit 1
fi

echo "Using GCP_HOST=$GCP_HOST"

response_file=$(mktemp)
servers_file=$(mktemp)

trap 'rm -f "$response_file" "$servers_file"' EXIT INT TERM

register_server() {
  api_url="$1"
  payload="$2"

  : > "$response_file"

  if http_code=$(curl -sS \
    --connect-timeout 10 \
    --max-time 30 \
    -o "$response_file" \
    -w '%{http_code}' \
    -X POST "$api_url" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$payload"); then
    curl_status=0
  else
    curl_status=$?
  fi

  response_body=$(cat "$response_file")

  echo "POST $api_url"
  echo "HTTP status: $http_code"
  echo "Curl status: $curl_status"

  if [ -n "$response_body" ]; then
    echo "Response:"
    printf '%s\n' "$response_body"
  else
    echo "Response body is empty."
  fi

  REGISTER_HTTP_CODE="$http_code"
  REGISTER_CURL_STATUS="$curl_status"
  REGISTER_RESPONSE="$response_body"
}

registration_missing() {
  if [ "$REGISTER_HTTP_CODE" = "404" ]; then
    return 0
  fi

  printf '%s' "$REGISTER_RESPONSE" |
    grep -Eqi \
      'server[ _-]*not[ _-]*found|not found|server_not_found|no[ _-]+matching[ _-]+server|does not exist|"updated"[[:space:]]*:[[:space:]]*(0|false)'
}

registration_succeeded() {
  if [ "$REGISTER_CURL_STATUS" -ne 0 ]; then
    return 1
  fi

  case "$REGISTER_HTTP_CODE" in
    2??)
      if printf '%s' "$REGISTER_RESPONSE" |
        grep -Eqi \
          '"(success|ok)"[[:space:]]*:[[:space:]]*false|"updated"[[:space:]]*:[[:space:]]*(0|false)'; then
        return 1
      fi

      if registration_missing; then
        return 1
      fi

      return 0
      ;;

    *)
      return 1
      ;;
  esac
}

# Extract only the port 700 server locations.
# Underscores and hyphens are now supported.
awk '
/^[[:space:]]*location \/[a-zA-Z0-9_-]+[[:space:]]*\{/ {
    path=$2
}

/proxy_pass http:\/\/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:700;/ {
    if (path == "") {
        next
    }

    target=$2
    gsub(";", "", target)
    gsub("http://", "", target)
    split(target, parts, ":")

    print path "|" parts[1]
    path=""
}
' "$NGINX_CONF" > "$servers_file"

if [ ! -s "$servers_file" ]; then
  echo "ERROR: No port 700 servers were found in $NGINX_CONF"
  exit 1
fi

while IFS="|" read -r gcp_path ip; do
  if [ -z "$gcp_path" ] || [ -z "$ip" ]; then
    continue
  fi

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

  echo ""
  echo "=================================================="
  echo "Registering IP: $ip"
  echo "GCP path: $gcp_path"
  echo "=================================================="

  case "$gcp_path" in
    /pussy_*)
      # These paths belong to the pussyvpn.com database.
      echo "PUSSY VPN path detected. Sending directly to API2."

      register_server "$API_URL2" "$payload"

      if ! registration_succeeded; then
        echo "ERROR: API2 failed to register $ip"
        exit 1
      fi

      echo "SUCCESS: Registered $ip using API2"
      ;;

    *)
      echo "Sending $ip to API1."

      register_server "$API_URL" "$payload"

      if registration_succeeded; then
        echo "SUCCESS: Registered $ip using API1"
        continue
      fi

      if registration_missing; then
        echo "$ip was not found on API1. Trying API2."

        register_server "$API_URL2" "$payload"

        if ! registration_succeeded; then
          echo "ERROR: API2 also failed to register $ip"
          exit 1
        fi

        echo "SUCCESS: Registered $ip using API2"
      else
        echo "ERROR: API1 failed with HTTP $REGISTER_HTTP_CODE"
        exit 1
      fi
      ;;
  esac
done < "$servers_file"

echo ""
echo "All GCP server registrations completed successfully."

nginx -t
exec nginx -g 'daemon off;'
