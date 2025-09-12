#!/usr/bin/env bash
# Captive Portal Auto-Login (generic)
# ---------------------------------------------------------------
# This script attempts to detect a captive portal and automatically
# perform the minimal steps required to gain internet access.
#
# DESIGN GOALS
# - Work with a wide range of captive portals (best effort).
# - Avoid exotic dependencies: only relies on curl, awk, sed, grep.
# - Be transparent: heavy comments explain each step and header choice.
# - Offer special handling for common vendors (e.g., Meraki/“network-auth.com”).
#
# SAFETY / ETHICS
# - Only use on networks where you have legitimate access.
# - This script merely automates the same actions you would do in a browser:
#   fetch portal page, accept terms, and follow the portal’s “Continue” URL.
# - No password cracking, no bypassing authentication, no prohibited use.
#
# REQUIREMENTS
# - bash 4+
# - curl (for HTTP requests, cookies, redirects, and headers)
# - awk/sed/grep (for small HTML heuristics; HTML parsing in shell is brittle)
#
# HOW IT WORKS (high level)
# 1) Detect if a captive portal blocks access (by probing known endpoints).
# 2) If blocked, request a plain HTTP page to trigger a redirect to the portal.
# 3) Try vendor-specific fast-paths (e.g., Meraki “Continue-Url” grant flow).
# 4) Otherwise, do a best-effort generic form submit (accept terms / continue).
# 5) Re-check connectivity and exit.
#
# NOTE ON MERAKI (example)
# Many Cisco Meraki guest portals present a “Continue to the Internet” button
# that runs JS to perform a HEAD request to obtain a “Continue-Url” header,
# then calls a /grant?continue_url=... endpoint. This script recreates that flow.
#
# ENVIRONMENT OVERRIDES
# - EMAIL:      Email to submit where a form offers/asks for it (optional).
# - FULLNAME:   Full name to submit where applicable (optional).
# - COMPANY:    Company/Organization field if present (optional).
# - UA:         Custom User-Agent. Default emulates a mainstream browser.
# - IFACE:      Network interface hint (used only for logging).
#
# USAGE
#   chmod +x captive-login.sh
#   ./captive-login.sh
#   EMAIL="me@example.com" FULLNAME="Jane Doe" ./captive-login.sh
#
set -Eeuo pipefail

# ------ Configuration knobs ---------------------------------------------------

: "${UA:=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36}"
: "${WORKDIR:=$(mktemp -d -t captive-XXXX)}"
: "${COOKIE_JAR:=$WORKDIR/cookies.txt}"
: "${DEBUG:=0}"           # set to 1 for verbose curl (-v)
CURL_DEBUG=()
(( DEBUG == 1 )) && CURL_DEBUG=(-v)

# Some well-known connectivity check URLs:
APPLE_CHECK="http://captive.apple.com/hotspot-detect.html"
GOOGLE_CHECK_204="http://connectivitycheck.gstatic.com/generate_204"
GOOGLE_CHECK_204_ALT="http://clients3.google.com/generate_204"

# A simple plain-HTTP URL to trigger captive redirect (avoid https):
TRIGGER_URL="http://example.com/"

# ------ Helpers ---------------------------------------------------------------

log() { printf "[%s] %s\n" "$(date +'%H:%M:%S')" "$*" >&2; }
cleanup() { rm -rf -- "${WORKDIR}" 2>/dev/null || true; }
trap cleanup EXIT

curl_base() {
  # A small wrapper that standardizes our curl options.
  # -L: follow redirects (except when we explicitly don’t want to)
  # -sS: silent except errors
  # -k:  tolerate bad/old TLS (some captive portals use weird certs)
  # -A:  set user agent (some portals behave differently by UA)
  # -b/-c: cookie jar for session continuity
  curl -sS -k "${CURL_DEBUG[@]}" \
       -A "$UA" \
       -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
       "$@"
}

have_internet() {
  # Heuristic: any of these checks succeeding indicates free internet.
  # 1) Google 204 returns status 204 with empty body when not captive.
  # 2) Alternative Google 204.
  # 3) Apple hotspot page returns an actual “Success” HTML (HTTP 200) when free.
  local code body
  code=$(curl_base -o /dev/null -w '%{http_code}' --max-time 5 "$GOOGLE_CHECK_204" || true)
  if [[ "$code" == "204" ]]; then return 0; fi

  code=$(curl_base -o /dev/null -w '%{http_code}' --max-time 5 "$GOOGLE_CHECK_204_ALT" || true)
  if [[ "$code" == "204" ]]; then return 0; fi

  body=$(curl_base --max-time 5 "$APPLE_CHECK" || true)
  if grep -qi "Success" <<<"$body"; then return 0; fi

  return 1
}

trigger_portal_redirect() {
  # Try to fetch a plain HTTP page *without* following redirects first,
  # so we can capture the redirect Location (if any).
  # -I = HEAD, -L disabled here (no -L) to read the 30x Location.
  log "Attempting to trigger captive portal redirect..."
  local headers
  headers=$(curl_base -I --max-time 8 "$TRIGGER_URL" || true)
  printf "%s" "$headers"
}

extract_header() {
  # Extract a header value (case-insensitive) from a raw header block.
  # Usage: extract_header "$headers" "Location"
  awk -v key="$2" '
    BEGIN{ IGNORECASE=1 }
    $0 ~ "^"key":" {
      # Join any continued header lines:
      value=$0
      while (getline nextline && nextline ~ /^[ \t]/) {
        value=value substr(nextline, index(nextline,$1))
      }
      # Split on the first ":" and trim
      sub(/^[^:]+:[ \t]*/, "", value)
      gsub(/\r/,"", value)
      print value
      exit
    }' <<<"$1"
}

normalize_url() {
  # Remove surrounding <> or quotes which some servers include
  sed -E 's/^[<"]+//; s/[>"]+$//' <<<"$1"
}

get_html() {
  # Fetch the HTML body of a URL and save it locally for later parsing.
  local url="$1"
  local out="${WORKDIR}/portal.html"
  log "Fetching portal page: $url"
  curl_base -L "$url" -o "$out" || true
  printf "%s" "$out"
}

find_first_form_action() {
  # Extremely naive form action extractor (first form only).
  # Looks for <form ... action="...">; defaults to current page if missing.
  # WARNING: HTML parsing in shell is fragile. This is a best-effort only.
  local html_file="$1"
  local base_url="$2"
  local action
  action=$(awk '
    BEGIN{IGNORECASE=1; action=""}
    /<form/ && action=="" {
      # Search for action="..."
      match(tolower($0), /action[[:space:]]*=[[:space:]]*("[^"]*"|'\''[^'\'']*'\''|[^[:space:]>]+)/, m)
      if (m[0] != "") {
        action=m[1]
        gsub(/^["'\'']|["'\'']$/, "", action)
        print action
        exit
      } else {
        # No explicit action -> empty means current page
        print ""
        exit
      }
    }' "$html_file")

  if [[ -z "$action" ]]; then
    printf "%s" "$base_url"
  elif [[ "$action" =~ ^https?:// ]]; then
    printf "%s" "$action"
  else
    # Resolve relative path against base href or base_url
    # Try to read <base href="..."> if present:
    local basehref
    basehref=$(awk '
      BEGIN{IGNORECASE=1}
      /<base[[:space:]]+href/ {
        match(tolower($0), /href[[:space:]]*=[[:space:]]*("[^"]*"|'\''[^'\'']*'\''|[^[:space:]>]+)/, m)
        if (m[1] != "") {
          v=m[1]; gsub(/^["'\'']|["'\'']$/, "", v); print v; exit
        }
      }' "$html_file")
    if [[ -n "$basehref" ]]; then
      printf "%s" "${basehref%/}/$action"
    else
      printf "%s" "${base_url%/}/$action"
    fi
  fi
}

submit_generic_form() {
  # Heuristic submit:
  # - Collect hidden fields and common checkboxes (terms/accept/tos)
  # - Add optional EMAIL/FULLNAME/COMPANY if corresponding inputs exist
  # - Perform POST to form action
  local html_file="$1"
  local base_url="$2"

  local action_url
  action_url=$(find_first_form_action "$html_file" "$base_url")

  # Collect hidden inputs and common consent fields:
  local post_data_file="${WORKDIR}/post-data.txt"
  : > "$post_data_file"

  # Hidden inputs:
  awk '
    BEGIN{IGNORECASE=1}
    /<input/ {
      # type=hidden
      t=""; n=""; v="";
      if (match(tolower($0), /type[[:space:]]*=[[:space:]]*("[^"]*"|'\''[^'\'']*'\''|[^[:space:]>]+)/, m)) {
        t=m[1]; gsub(/^["'\'']|["'\'']$/, "", t)
      }
      if (match(tolower($0), /name[[:space:]]*=[[:space:]]*("[^"]*"|'\''[^'\'']*'\''|[^[:space:]>]+)/, m)) {
        n=m[1]; gsub(/^["'\'']|["'\'']$/, "", n)
      }
      if (match($0, /value[[:space:]]*=[[:space:]]*("[^"]*"|'\''[^'\'']*'\''|[^[:space:]>]+)/, m)) {
        v=m[1]; gsub(/^["'\'']|["'\'']$/, "", v)
      }
      if (tolower(t)=="hidden" && n!="") {
        gsub(/&/,"%26",v); gsub(/\+/,"%2B",v)
        printf("%s=%s\n", n, v)
      }
    }' "$html_file" >> "$post_data_file"

  # Common consent checkboxes/fields (best-effort guess):
  # terms, accept, agree, policy, aup
  for key in terms accept agree policy aup; do
    if grep -iq "name=[\"']\?$key[\"']\?" "$html_file"; then
      printf "%s=%s\n" "$key" "on" >> "$post_data_file"
    fi
  done

  # Optional email/fullname/company fields if present:
  if [[ -n "${EMAIL:-}" ]] && grep -iqE 'name=["'\'']?(email|mail)["'\'']?' "$html_file"; then
    printf "email=%s\n" "$(printf %s "$EMAIL" | sed 's/&/%26/g;s/+/ /g;s/ /%20/g')" >> "$post_data_file"
  fi
  if [[ -n "${FULLNAME:-}" ]] && grep -iqE 'name=["'\'']?(name|fullname|full_name)["'\'']?' "$html_file"; then
    printf "fullname=%s\n" "$(printf %s "$FULLNAME" | sed 's/&/%26/g;s/+/ /g;s/ /%20/g')" >> "$post_data_file"
  fi
  if [[ -n "${COMPANY:-}" ]] && grep -iqE 'name=["'\'']?(company|org|organization)["'\'']?' "$html_file"; then
    printf "company=%s\n" "$(printf %s "$COMPANY" | sed 's/&/%26/g;s/+/ /g;s/ /%20/g')" >> "$post_data_file"
  fi

  # Compose URL-encoded body:
  local body
  body=$(paste -sd'&' "$post_data_file")

  log "Submitting generic form to: $action_url"
  curl_base -L -H "Content-Type: application/x-www-form-urlencoded" \
            --data "$body" \
            "$action_url" \
            -o "${WORKDIR}/post-response.html" || true
}

meraki_continue_grant() {
  # Implements the Meraki flow commonly seen on na.network-auth.com:
  # - Do a HEAD request with X-Requested-With: XMLHttpRequest to the portal URL
  # - Read "Continue-Url" response header
  # - Call /grant?continue_url=<Continue-Url> to finalize access
  #
  # This mirrors the “Continue to the Internet” button behavior observed in
  # typical Meraki splash pages.
  local portal_base="$1"

  log "Attempting Meraki-style Continue-Url flow..."
  # HEAD with custom header to obtain Continue-Url (case-insensitive compare)
  local headers continue_url grant_url
  headers=$(curl_base -I -H "X-Requested-With: XMLHttpRequest" "$portal_base" || true)
  continue_url=$(extract_header "$headers" "Continue-Url" || true)

  if [[ -z "$continue_url" ]]; then
    log "No Continue-Url header found; Meraki fast-path not applicable."
    return 1
  fi

  # Some portals provide a template like:
  #   https://.../grant?continue_url=CONTINUE_URL_PLACEHOLDER
  # If we know the pattern, we can try to build it. Otherwise, guess a common path.
  # Try typical Meraki path:
  if [[ "$portal_base" =~ /splash/([^/]+)/ ]]; then
    local token="${BASH_REMATCH[1]}"
    grant_url="${portal_base%/splash/*}/splash/${token}/grant?continue_url=$(printf %s "$continue_url" | sed 's/"/%22/g;s/ /%20/g')"
  else
    # Fallback guess: append /grant path
    grant_url="${portal_base%/}/grant?continue_url=$(printf %s "$continue_url" | sed 's/"/%22/g;s/ /%20/g')"
  fi

  log "Grant URL: $grant_url"
  curl_base -L "$grant_url" -o "${WORKDIR}/grant.html" || true
}

main() {
  log "Starting captive portal check (iface=${IFACE:-unknown})"
  if have_internet; then
    log "Internet already available. Nothing to do."
    exit 0
  fi

  # Trigger a redirect to the captive portal
  local head_headers location portal_url html_file
  head_headers="$(trigger_portal_redirect)"
  location="$(extract_header "$head_headers" "Location" || true)"
  location="$(normalize_url "${location:-}")"

  if [[ -z "$location" ]]; then
    # Some portals do inline HTML interception; try fetching body anyway
    log "No redirect Location header; attempting to fetch trigger URL body."
    html_file="$(get_html "$TRIGGER_URL")"
    # Try to find a link that looks like a splash/login portal:
    portal_url=$(awk '
      BEGIN{IGNORECASE=1}
      /https?:\/\/[^"'\'' ]*(splash|login|portal|guest|captive|network-auth)[^"'\'' ]*/ {
        match($0, /https?:\/\/[^"'\'' )]+/, m); print m[0]; exit
      }' "$html_file")
  else
    portal_url="$location"
  fi

  if [[ -z "$portal_url" ]]; then
    log "Could not determine portal URL. Exiting with failure."
    exit 2
  fi

  log "Detected portal URL: $portal_url"

  # Try vendor-specific fast path: Meraki (na.network-auth.com, etc.)
  if grep -qiE 'network-auth\.com|meraki' <<<"$portal_url"; then
    if meraki_continue_grant "$portal_url"; then
      if have_internet; then
        log "Access obtained via Meraki fast-path."
        exit 0
      fi
      log "Meraki fast-path attempted; internet still blocked. Continuing..."
    fi
  fi

  # Generic best-effort submit (accept terms / continue)
  html_file="$(get_html "$portal_url")"
  submit_generic_form "$html_file" "$portal_url"

  # Final connectivity check
  if have_internet; then
    log "Internet access obtained."
    exit 0
  else
    log "Still behind captive portal (or network requires manual steps)."
    log "Check: $WORKDIR for captured HTML and responses for troubleshooting."
    exit 3
  fi
}

main "$@"
