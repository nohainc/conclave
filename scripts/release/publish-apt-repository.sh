#!/usr/bin/env bash
# Publishes package data only to a separate GitHub Pages repository. Its gh-pages
# branch must already exist and Pages must be configured to serve that branch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${CONCLAVE_APT_PRIVATE_KEY:?}" "${CONCLAVE_APT_SIGNING_FINGERPRINT:?}" "${CONCLAVE_APT_REPOSITORY:?}" "${GH_TOKEN:?}"
[[ "$CONCLAVE_APT_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
[[ "$CONCLAVE_APT_REPOSITORY" != "${GITHUB_REPOSITORY:-nohainc/conclave}" ]] || { echo 'Package hosting must be separate from source.' >&2; exit 1; }
CANDIDATES="${1:?Supply candidate package directory}"
TEMP="$(mktemp -d)"
trap 'gpgconf --kill gpg-agent || true; rm -rf "$TEMP"' EXIT
export GNUPGHOME="$TEMP/gnupg"
mkdir -m 700 "$GNUPGHOME"
printf '%s' "$CONCLAVE_APT_PRIVATE_KEY" | gpg --batch --import
unset CONCLAVE_APT_PRIVATE_KEY
# gh's credential helper avoids embedding the token in the git remote or logs.
gh auth setup-git
git clone --quiet --single-branch --branch gh-pages "https://github.com/$CONCLAVE_APT_REPOSITORY.git" "$TEMP/repository"
PACKAGES=()
while IFS= read -r -d '' package; do PACKAGES+=("$package"); done < <(find "$CANDIDATES" -type f -name '*.deb' -print0)
[[ ${#PACKAGES[@]} == 2 ]] || { echo 'Expected exactly the tested amd64 and arm64 packages.' >&2; exit 1; }
python3 "$ROOT/scripts/release/build-apt-repository.py" --output "$TEMP/repository" \
  --signing-key "$CONCLAVE_APT_SIGNING_FINGERPRINT" "${PACKAGES[@]}"
(cd "$TEMP/repository" && git add pool dists conclave-archive-keyring.gpg .nojekyll && \
  git -c user.name='Conclave Releases' -c user.email='releases@conclaveax.com' commit -m 'Publish tested Conclave Workspace packages' && \
  git push origin HEAD:gh-pages)
# The publisher token must trigger the target repository's Pages build. The
# source repository's automatic GITHUB_TOKEN is intentionally not used.
echo "Published package metadata to $CONCLAVE_APT_REPOSITORY (await Pages deployment)."
