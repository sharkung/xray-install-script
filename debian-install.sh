#!/usr/bin/env bash

# Debian 13 (x86_64) Xray/REALITY + Hysteria 2 installer.
# Target OS: Debian 13 (trixie), x86_64.
# Uses systemd instead of Alpine OpenRC and apt instead of apk.
# Automatic configuration uses Amazon as the REALITY target.
# The regional/manual branch and Hysteria 2 branch are retained.

XRAY_HOME="/usr/local/bin/xray"
XRAY_BIN="${XRAY_HOME}/xray"
XRAY_CLI_LINK="/usr/local/sbin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_ASSET_DIR="/usr/local/share/xray"
XRAY_LOG_DIR="/var/log/xray"
REALITY_TARGET="://amazon.com"
REALITY_SNI="://amazon.com"

log(){
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn(){
    printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die(){
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

getIP(){
    local serverIP=""

    serverIP=$(curl -4 -fsS --connect-timeout 5 --max-time 10 \
        https://cloudflare.com 2>/dev/null |
        awk -F= '$1 == "ip" {print $2; exit}' || true)

    if [[ -z "${serverIP}" ]]; then
        serverIP=$(curl -6 -fsS --connect-timeout 5 --max-time 10 \
            https://cloudflare.com 2>/dev/null |
            awk -F= '$1 == "ip" {print $2; exit}' || true)
    fi

    printf '%s\n' "${serverIP:-SERVER_IP}"
}

formatUriHost(){
    local host=$1
    if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
        printf '[%s]' "${host}"
    else
        printf '%s' "${host}"
    fi
}

getShortId(){
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

selectRealityPort(){
    local input=""

    if [[ -n "${XRAY_PORT:-}" ]]; then
        getPort=${XRAY_PORT}
    else
        read -r -p "REALITY listen port: " input || true
        getPort=${input:-443}
    fi

    [[ "${getPort}" =~ ^[0-9]+$ ]] || die "Invalid port: ${getPort}"
    (( getPort >= 1 && getPort <= 65535 )) || die "Port must be between 1 and 65535."

    if (( getPort != 443 )); then
        warn "Current Xray releases warn when REALITY listens on a non-443 port."
    fi
}

generateRealityCredentials(){
    local keyOutput

    v2uuid=$(${XRAY_BIN} uuid | tr -d '\r\n')
    keyOutput=$(${XRAY_BIN} x25519)

    rePrivateKey=$(printf '%s\n' "${keyOutput}" |
        awk -F':[[:space:]]*' '$1 == "PrivateKey" {print $2; exit}' |
        tr -d '\r')

    rePublicKey=$(printf '%s\n' "${keyOutput}" |
        awk -F':[[:space:]]*' '$1 ~ /^Password( \(PublicKey\))?$/ {print $2; exit}' |
        tr -d '\r')

    shortId1=$(getShortId)
    shortId2=$(getShortId)

    [[ -n "${v2uuid}" ]] || die "xray uuid returned an empty value."
    [[ -n "${rePrivateKey}" ]] || die "Could not parse PrivateKey from xray x25519."
    [[ -n "${rePublicKey}" ]] || die "Could not parse Password (PublicKey) from xray x25519."
    [[ "${shortId1}" =~ ^[0-9a-f]{16}$ ]] || die "Failed to generate shortId."
}

validateXrayConfig(){
    local configFile=$1 output

    if ! output=$(XRAY_LOCATION_ASSET="${XRAY_ASSET_DIR}" \
        "${XRAY_BIN}" run -test -format json -c "${configFile}" 2>&1); then
        printf '%s\n' "${output}" >&2
        return 1
    fi

    [[ -n "${output}" ]] && printf '%s\n' "${output}"
    return 0
}

installRealityConfig(){
    local tempConfig backupConfig=""
    tempConfig=$(mktemp --suffix=.json)

    cat >"${tempConfig}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "port": ${getPort},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${v2uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${rePrivateKey}",
          "maxTimeDiff": 0,
          "shortIds": [
            "${shortId1}",
            "${shortId2}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

    validateXrayConfig "${tempConfig}" || {
        warn "Generated config kept at ${tempConfig} for troubleshooting."
        die "Generated Xray configuration did not pass validation."
    }

    mkdir -p "${XRAY_CONFIG_DIR}"
    if [[ -f "${XRAY_CONFIG}" ]]; then
        backupConfig="${XRAY_CONFIG}.bak.$(date '+%Y%m%d%H%M%S')"
        cp -p "${XRAY_CONFIG}" "${backupConfig}"
        log "Previous configuration backed up to ${backupConfig}."
    fi

    install -m 0600 "${tempConfig}" "${XRAY_CONFIG}"
    rm -f "${tempConfig}"

    systemctl restart xray || die "Xray failed to restart."
    sleep 1
    systemctl is-active --quiet xray || die "Xray is not running; check ${XRAY_LOG_DIR}/xray.err or run: journalctl -u xray -n 100 --no-pager."
}

configReality(){
    generateRealityCredentials
    selectRealityPort

    sniName=${REALITY_SNI}
    serverName=${REALITY_TARGET%:*}
    export sniName serverName

    installRealityConfig
}

configRealityRegion(){
    local userInput index tempConfig
    destNames=("://t-mobile.com" "://arm.com" "www.tsukuba.ac.jp" "://hongkongdisneyland.com" "://china-airlines.com" "sigtelinc.com" "www.bouyguestelecom.fr" "www.mercedes-benz.de" "www.incredibleindia.gov.in" "://amazon.com")
    sniNames=("://t-mobile.com" "://arm.com" "www.tsukuba.ac.jp" "://hongkongdisneyland.com" "://china-airlines.com" "://sigtelinc.com" "www.bouygtel.fr" "://mercedes-benz.com" "www.incredibleindia.org" "://amazon.com")

    echo "Please select a region:"
    echo "1. US"
    echo "2. UK"
    echo "3. JP"
    echo "4. HK"
    echo "5. TW"
    echo "6. SG"
    echo "7. FR"
    echo "8. DE"
    echo "9. IN"
    echo "10. Others"
    read -r userInput

    if [[ "${userInput}" =~ ^([1-9]|10)$ ]]; then
        index=$((userInput - 1))
        serverName=${destNames[$index]}
        sniName=${sniNames[$index]}
    else
        echo "Invalid selection. Please enter a number between 1 and 10."
        return 1
    fi

    generateRealityCredentials
    selectRealityPort
    tempConfig=$(mktemp --suffix=.json)

    cat >"${tempConfig}" <<EOF
{
  "inbounds": [
    {
      "port": ${getPort},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${v2uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${serverName}:443",
          "xver": 0,
          "serverNames": ["${sniName}"],
          "privateKey": "${rePrivateKey}",
          "maxTimeDiff": 0,
          "shortIds": ["${shortId1}", "${shortId2}"]
        }
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ]
}
EOF

    validateXrayConfig "${tempConfig}" || {
        warn "Generated config kept at ${tempConfig} for troubleshooting."
        die "Generated manual configuration did not pass validation."
    }

    [[ -f "${XRAY_CONFIG}" ]] && cp -p "${XRAY_CONFIG}" "${XRAY_CONFIG}.bak.$(date '+%Y%m%d%H%M%S')"
    install -m 0600 "${tempConfig}" "${XRAY_CONFIG}"
    rm -f "${tempConfig}"
    systemctl restart xray
}

detectXrayAsset(){
    case "$(uname -m)" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l|armv7) echo "arm32-v7a" ;;
        armv6l|armv6) echo "arm32-v6" ;;
        i386|i486|i586|i686) echo "32" ;;
        riscv64) echo "riscv64" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
}

getLatestXrayVersion(){
    local releaseJson effectiveUrl version

    if [[ -n "${XRAY_VERSION:-}" ]]; then
        echo "v${XRAY_VERSION#v}"
        return
    fi

    releaseJson=$(curl -fsSL --connect-timeout 10 --max-time 30 \
        --retry 3 --retry-delay 2 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        https://github.com 2>/dev/null || true)

    version=$(printf '%s\n' "${releaseJson}" |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1)

    if [[ -z "${version}" ]]; then
        effectiveUrl=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            --connect-timeout 10 --max-time 30 \
            https://github.com 2>/dev/null || true)
        version=${effectiveUrl##*/}
    fi

    [[ "${version}" == v* ]] || die "Unable to determine the latest Xray release."
    echo "${version}"
}

installXray(){
    local xrayVersion xrayAsset tempDir zipFile digestFile downloadUrl
    local expectedSha actualSha choice

    log "Installing Debian dependencies..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash ca-certificates curl grep openssl unzip coreutils sed gawk
    update-ca-certificates >/dev/null 2>&1 || true

    xrayVersion=$(getLatestXrayVersion)
    xrayAsset=$(detectXrayAsset)
    tempDir=$(mktemp -d)
    zipFile="${tempDir}/xray.zip"
    digestFile="${tempDir}/xray.zip.dgst"
    downloadUrl="https://github.com{xrayVersion}/Xray-linux-${xrayAsset}.zip"

    log "Downloading Xray ${xrayVersion} for $(uname -m)..."
    curl -fL --connect-timeout 10 --max-time 180 \
        --retry 3 --retry-delay 2 \
        -o "${zipFile}" "${downloadUrl}" || {
            rm -rf "${tempDir}"
            die "Failed to download Xray."
        }

    if curl -fL --connect-timeout 10 --max-time 30 \
