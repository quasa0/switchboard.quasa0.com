#!/bin/bash
# Run only with authorization to publish the website.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check-site.py
SWITCHBOARD_DEPLOY_RESULT=$(vercel deploy site --prod --yes --non-interactive --format json)
SWITCHBOARD_DEPLOYMENT=$(printf '%s' "$SWITCHBOARD_DEPLOY_RESULT" | python3 -c 'import json,sys; result=json.load(sys.stdin)["deployment"]; assert result["readyState"] == "READY"; print(result["url"])')
# The generated deployment URL can require Vercel login. Verify its production
# alias, then smoke the public installation path without weakening protection.
vercel inspect "$SWITCHBOARD_DEPLOYMENT" --format json | python3 -c 'import json,sys; result=json.load(sys.stdin); assert result["readyState"] == "READY"; assert "switchboard.quasa0.com" in result["aliases"]'
python3 scripts/smoke-site.py https://switchboard.quasa0.com
if [ "$(uname -s)" = Darwin ]; then python3 scripts/test-published-updater.py; fi
printf 'Verified: %s\n' "$SWITCHBOARD_DEPLOYMENT"
