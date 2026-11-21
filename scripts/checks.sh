#!/usr/bin/env bash
# The proofs, one per pipeline step:
#   direct    the workload has no route out without the proxy
#   allowed   package installs through the proxy work (pip and apk)
#   blocked   everything else is turned back by Squid
#   ha        with one proxy down, egress still works
#   audit     every request is on record: cleared vs turned back
set -euo pipefail
w() { docker exec workload sh -c "$1"; }

case "$1" in
  direct)
    if w "env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy python3 -c \"import urllib.request; urllib.request.urlopen('https://pypi.org', timeout=5)\"" 2>/dev/null; then
      echo "FAIL  the workload reached pypi.org without the proxy"; exit 1
    fi
    echo "Without the proxy: pypi.org is unreachable (the private network has no gateway)"
    w "ip route 2>/dev/null || true" | sed 's/^/route: /'
    echo "PASS  no direct route to the internet"
    ;;
  allowed)
    w "pip install --quiet --root-user-action=ignore --disable-pip-version-check --no-cache-dir requests==2.32.3 && python3 -c 'import requests; print(\"pip: installed requests\", requests.__version__, \"from pypi.org\")'"
    w "apk add --quiet --no-cache jq && echo \"apk: installed \$(jq --version) from dl-cdn.alpinelinux.org\""
    w "python3 -c \"import requests; r = requests.get('https://deb.debian.org/debian/', timeout=10); print('https://deb.debian.org ->', r.status_code)\""
    echo "PASS  package repositories reachable through the proxy"
    ;;
  blocked)
    fails=0
    for url in https://example.com https://github.com https://api.openai.com http://neverssl.com; do
      # Squid answers 403 itself: as a refused CONNECT tunnel for HTTPS, as a 403 page for plain HTTP
      out=$(w "python3 -c \"
import requests
try:
    r = requests.get('$url', timeout=10)
    print('turned back: 403' if r.status_code == 403 else 'REACHED %d' % r.status_code)
except requests.exceptions.ProxyError as e:
    print('turned back: 403' if '403' in str(e) else 'error: ' + str(e)[:80])
\"" 2>&1)
      echo "$url -> $out"
      [[ $out == REACHED* ]] && fails=$((fails + 1))
    done
    [ "$fails" = 0 ] || { echo "FAIL  $fails destination(s) outside the allow list were reachable"; exit 1; }
    echo "PASS  everything outside the allow list is turned back"
    ;;
  ha)
    docker stop squid1 >/dev/null
    sleep 3
    w "pip download --quiet --root-user-action=ignore --disable-pip-version-check --no-cache-dir --no-deps -d /tmp/ha idna==3.10 && echo 'With squid1 down: pip still downloads from pypi.org through squid2'"
    docker start squid1 >/dev/null
    echo "PASS  egress survives losing a proxy"
    ;;
  audit)
    logs=$( (docker logs squid1; docker logs squid2) 2>/dev/null | grep -E ' (TCP|NONE)_[A-Z_]+/[0-9]{3} ' || true)
    cleared=$(grep -cE 'TCP_TUNNEL/200|TCP_MISS/200' <<< "$logs" || true)
    denied=$(grep -cE 'TCP_DENIED/403|NONE_NONE/403' <<< "$logs" || true)
    echo "Cleared: $cleared requests · Turned back: $denied requests"
    echo "Turned back, by destination:"
    grep -E '/403 ' <<< "$logs" | awk '{print $5}' | sed -E 's#^https?://##; s#[:/].*##' | sort | uniq -c | sed 's/^/  /'
    echo "Cleared, by destination:"
    grep -E 'TCP_TUNNEL/200|TCP_MISS/200' <<< "$logs" | awk '{print $5}' | sed -E 's#^https?://##; s#[:/].*##' | sort | uniq -c | sed 's/^/  /'
    [ "$cleared" -gt 0 ] && [ "$denied" -gt 0 ]
    echo "PASS  every request is on record"
    ;;
esac
