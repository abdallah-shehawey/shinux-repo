#!/usr/bin/env bash
# Rewrite the "pool" release's title and description from what is attached.
#
# The packages live in that release's assets, and GitHub renders an asset list
# alphabetically with no grouping of any kind: every version of every package,
# in three formats, interleaved with apt's indexes and pacman's database. The
# description is the one part of the release this repository controls, so the
# grouping goes there -- see gen-pool-notes.py, which builds it.
#
# Generated on every publish rather than written once by hand, because a
# hand-written index is wrong the moment the next version lands, which is
# exactly the mess it exists to clean up.
#
# Reads nothing but the API listing: names, sizes and URLs all come back with
# it, so no package is downloaded to be indexed. That matters here more than it
# looks -- the counters on these assets are the only measure of what real users
# install, and a publish that fetched its own pool would drown them.
#
# Run it AFTER pool-assets.sh, or the version this run just built is described
# by nothing.
#
#   scripts/pool-notes.sh             rewrite title + description; skip with no token
#   scripts/pool-notes.sh --require   fail instead of skipping (what CI wants)
#   scripts/pool-notes.sh --print     print the description, change nothing
set -euo pipefail
source "$(dirname "$0")/config.sh"

require=0
print_only=0
case "${1:-}" in
  --require) require=1 ;;
  --print)   print_only=1 ;;
  "")        ;;
  *)         die "unknown argument: $1" ;;
esac

source "$(dirname "$0")/lib-pool.sh"

if [ -z "${pool_token}" ]; then
  [ "${require}" -eq 1 ] && die "no GH_TOKEN or GITHUB_TOKEN in the environment"
  printf '\033[33mwarning:\033[0m no GH_TOKEN or GITHUB_TOKEN; leaving the release description alone\n' >&2
  exit 0
fi

command -v curl    >/dev/null || die "curl is required to rewrite the description"
command -v python3 >/dev/null || die "python3 is required to rewrite the description"

release_id="$(pool_release_id)"
[ -n "${release_id}" ] || die "there is no ${POOL_TAG} release to describe"

work="${BUILD_DIR}/pool-notes"
mkdir -p "${work}"
trap 'rm -rf "${work}"' EXIT

# ------------------------------------------------------- what is attached ---
# Two listings joined rather than one: pool_assets is read elsewhere with a
# two-field `read`, so a third column there would silently land inside the URL.
pool_assets      "${release_id}" > "${work}/urls.tsv"
pool_asset_stats "${release_id}" > "${work}/stats.tsv"
awk -F'\t' 'NR==FNR { stat[$1] = $2 "\t" $3; next } { print $1 "\t" $2 "\t" stat[$1] }' \
    "${work}/stats.tsv" "${work}/urls.tsv" > "${work}/assets.tsv"

# --------------------------------------------------- what each package is ---
# The one-line summary already written for the package manager, reused for the
# heading rather than a second description kept in step by hand. Sourced in a
# subshell: these files set two dozen variables each, and config.sh's are still
# live in this one.
: > "${work}/summaries.tsv"
while IFS= read -r env; do
  (
    # shellcheck source=/dev/null
    source "${env}"
    if [ -n "${PKG_NAME:-}" ]; then
      printf '%s\t%s\n' "${PKG_NAME}" "${PKG_SUMMARY:-}"
    fi
  ) >> "${work}/summaries.tsv"
done < <(find "${ROOT_DIR}/packages" -mindepth 2 -maxdepth 2 -name metadata.env | sort)

# The two that add the repository itself have no packages/ directory: they are
# generated, and these are the summaries gen-release-packages.sh gives them.
printf '%s\t%s\n' "${REPO_ID}-release"          "${REPO_NAME} configuration and GPG key" >> "${work}/summaries.tsv"
printf '%s\t%s\n' "${REPO_ID}-archive-keyring"  "${REPO_NAME} apt sources and signing key" >> "${work}/summaries.tsv"

# ------------------------------------------------------------ the writing ---
"$(dirname "$0")/gen-pool-notes.py" "${work}/assets.tsv" "${work}/summaries.tsv" > "${work}/body.md"

if [ "${print_only}" -eq 1 ]; then
  cat "${work}/body.md"
  exit 0
fi

# The title comes along, so this script owns everything about the release that
# a person reads. pool-assets.sh names it at creation, but that fires once and
# never again -- a release created under an older title would keep it for ever
# otherwise.
#
# Only when something actually changed. A publish that rewrites an identical
# description edits the release for nothing, and GitHub shows an edit as an
# edit.
code="$(gh_api GET "${pool_api}/releases/${release_id}")"
[ "${code}" = "200" ] || pool_fail "could not read the ${POOL_TAG} release (HTTP ${code})"
pool_json 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("body") or "")' > "${work}/current.md"
current_title="$(pool_json 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("name") or "")')"

if [ "${current_title}" = "${POOL_TITLE}" ] && cmp -s "${work}/current.md" "${work}/body.md"; then
  info "the ${POOL_TAG} release already matches what is attached to it"
  exit 0
fi

python3 -c 'import json,sys; json.dump({"name": sys.argv[1], "body": open(sys.argv[2]).read()}, sys.stdout)' \
    "${POOL_TITLE}" "${work}/body.md" > "${work}/patch.json"

code="$(gh_api PATCH "${pool_api}/releases/${release_id}" \
        --header "Content-Type: application/json" \
        --data @"${work}/patch.json")"
[ "${code}" = "200" ] || pool_fail "could not update the ${POOL_TAG} release (HTTP ${code})"

info "rewrote \"${POOL_TITLE}\" ($(wc -l < "${work}/body.md") lines)"
