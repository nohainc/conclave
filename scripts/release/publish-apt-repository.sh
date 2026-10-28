#!/usr/bin/env bash
# Sign only tested packages, retain immutable versions on a package-data branch,
# and export a source-free tree for the official GitHub Pages deployment action.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${CONCLAVE_APT_PRIVATE_KEY:?}" "${CONCLAVE_APT_SIGNING_FINGERPRINT:?}" "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}"
[[ "${GITHUB_REF:-}" == refs/heads/main ]] || { echo 'Publish only from main.' >&2; exit 1; }
[[ "$(gh repo view "$GITHUB_REPOSITORY" --json visibility --jq .visibility)" == PUBLIC ]] || { echo 'APT hosting requires a public repository.' >&2; exit 1; }
CANDIDATES="${1:?Supply tested candidate package directory}"
OUTPUT="${2:-$ROOT/dist/apt-repository}"
BRANCH=apt-repository
TEMP="$(mktemp -d)"
trap 'gpgconf --kill gpg-agent || true; rm -rf "$TEMP"' EXIT
export GNUPGHOME="$TEMP/gnupg"
mkdir -m 700 "$GNUPGHOME"
printf '%s' "$CONCLAVE_APT_PRIVATE_KEY" | gpg --batch --import
unset CONCLAVE_APT_PRIVATE_KEY
gh auth setup-git
REMOTE="https://github.com/$GITHUB_REPOSITORY.git"
if [[ -n "$(git ls-remote --heads "$REMOTE" "$BRANCH")" ]]; then
  git clone --quiet --single-branch --branch "$BRANCH" "$REMOTE" "$TEMP/repository"
else
  git init --quiet --initial-branch="$BRANCH" "$TEMP/repository"
  git -C "$TEMP/repository" remote add origin "$REMOTE"
fi
PACKAGES=()
while IFS= read -r -d '' package; do PACKAGES+=("$package"); done < <(find "$CANDIDATES" -type f -name '*.deb' -print0)
[[ ${#PACKAGES[@]} == 2 ]] || { echo 'Expected tested amd64 and arm64 packages.' >&2; exit 1; }
# Independently check the exact architecture/version pair before using the key.
python3 - "${CONCLAVE_WORKSPACE_VERSION:?}" "${PACKAGES[@]}" <<'PY'
import subprocess, sys
version = sys.argv[1]
seen = set()
for package in sys.argv[2:]:
    fields = subprocess.check_output(['dpkg-deb', '--field', package, 'Package', 'Version', 'Architecture'], text=True)
    info = dict(line.split(': ', 1) for line in fields.splitlines())
    assert info['Package'] == 'conclave-workspace' and info['Version'] == version
    assert info['Architecture'] not in seen
    seen.add(info['Architecture'])
assert seen == {'amd64', 'arm64'}
PY
python3 "$ROOT/scripts/release/build-apt-repository.py" --output "$TEMP/repository" \
  --signing-key "$CONCLAVE_APT_SIGNING_FINGERPRINT" "${PACKAGES[@]}"
BASE_URL="https://${GITHUB_REPOSITORY%%/*}.github.io/${GITHUB_REPOSITORY#*/}"
python3 - "$ROOT/packaging/linux/apt-index.html" "$TEMP/repository/index.html" "$BASE_URL" "$CONCLAVE_APT_SIGNING_FINGERPRINT" "$CONCLAVE_WORKSPACE_VERSION" <<'PY'
import html, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
text = text.replace('@BASE_URL@', html.escape(sys.argv[3])).replace('@FINGERPRINT@', html.escape(sys.argv[4])).replace('@VERSION@', html.escape(sys.argv[5]))
pathlib.Path(sys.argv[2]).write_text(text)
PY
(cd "$TEMP/repository" && git add pool dists conclave-archive-keyring.gpg .nojekyll index.html && \
  git -c user.name='Syntila Releases' -c user.email='releases@conclaveax.com' commit -m "Publish Syntila Workspace $CONCLAVE_WORKSPACE_VERSION" && \
  git push origin "HEAD:$BRANCH")
# Explicit whitelist: never upload .git, source code or signing material to Pages.
mkdir -p "$OUTPUT"
for entry in pool dists conclave-archive-keyring.gpg .nojekyll index.html; do
  cp -R "$TEMP/repository/$entry" "$OUTPUT/"
done
echo "Prepared signed APT site for $BASE_URL; Pages deployment follows."
