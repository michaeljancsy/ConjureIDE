#!/bin/bash
#
# check-app-groups.sh — Fail if any bundle inside an app claims an App Group
# that its own embedded provisioning profile doesn't authorize.
#
# Usage: ./scripts/check-app-groups.sh path/to/ConjureDSP.app
#
# Since macOS 15, a process that opens a `group.`-style App Group container
# without profile authorization triggers the "would like to access data from
# other apps" prompt, and the file call blocks until the user answers. 3.1.0
# shipped that way: the extension's Developer ID profile only listed
# `A4R63LAVLS.*`, so every new user got the prompt (issue #370) and the
# plugin's first PresetManager directory create hung behind it (Sentry
# CONJUREDSP-6Q). Debug builds use team profiles that do include the group,
# so this never shows up in development.
#
# Checks the app and every nested .app/.appex/.xpc (not ExportTemplate.zip,
# whose exported AUs are ad-hoc signed by design). A claimed group passes if
# it matches an entry in the bundle's embedded profile (entries may end in
# `*`), or, with no profile, if it is prefixed with the signing team ID.

set -euo pipefail

[ $# -eq 1 ] || { echo "Usage: $0 <path/to/App.app>" >&2; exit 2; }
APP="${1%/}"
[ -d "$APP" ] || { echo "error: $APP is not a directory" >&2; exit 1; }

BUNDLES=("$APP")
while IFS= read -r b; do BUNDLES+=("$b"); done < <(
    find "$APP/Contents" -type d \( -name '*.app' -o -name '*.appex' -o -name '*.xpc' \) | sort
)

/usr/bin/python3 -u - "${BUNDLES[@]}" <<'PY'
import fnmatch, os, plistlib, subprocess, sys

GROUPS = "com.apple.security.application-groups"

def run(*cmd):
    return subprocess.run(cmd, capture_output=True, check=True).stdout

def entitlements(bundle):
    out = run("codesign", "-d", "--entitlements", "-", "--xml", bundle)
    return plistlib.loads(out) if out.strip() else {}

def team_id(bundle):
    info = subprocess.run(["codesign", "-dv", bundle], capture_output=True, text=True).stderr
    for line in info.splitlines():
        if line.startswith("TeamIdentifier="):
            return line.split("=", 1)[1]
    return None

app = sys.argv[1]
failures = 0
for bundle in sys.argv[1:]:
    claimed = entitlements(bundle).get(GROUPS) or []
    if not claimed:
        continue
    name = os.path.relpath(bundle, os.path.dirname(app))
    profile_path = os.path.join(bundle, "Contents", "embedded.provisionprofile")
    if os.path.exists(profile_path):
        profile = plistlib.loads(run("security", "cms", "-D", "-i", profile_path))
        allowed = profile.get("Entitlements", {}).get(GROUPS) or []
        source = f"profile allows {allowed}"
        ok = lambda g: any(fnmatch.fnmatchcase(g, pattern) for pattern in allowed)
    else:
        team = team_id(bundle)
        source = f"no embedded profile; team {team}"
        ok = lambda g: team is not None and g.startswith(team + ".")
    for group in claimed:
        if ok(group):
            print(f"  ok       {name}: {group}")
        else:
            print(f"  MISSING  {name}: {group} ({source})")
            failures += 1

if failures:
    print(f"error: {failures} App Group claim(s) not authorized. On macOS 15+ users get an "
          "'access data from other apps' prompt and the first container access blocks until "
          "they answer. Enable the group on the App ID in the Apple Developer portal, "
          "regenerate and install the Developer ID profile, then rebuild.", file=sys.stderr)
    sys.exit(1)
print("App Groups: every claim is authorized")
PY
