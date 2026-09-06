#!/usr/bin/env bash
# Upload every package in the pool to the assets of the "pool" release.
#
# The release is where the packages live now. docs/ is assembled from it on
# each publish and shipped to Pages as an artifact, so nothing here is in git:
# a clone of this repository is a few megabytes rather than the four gigabytes
# of history that committing 270 MB per version had built up.
#
# It is also the one place GitHub counts a download. Pages reports nothing at
# all, so an install that came from `dnf install` used to be invisible, and the
# numbers on the releases page only ever moved for someone who clicked a link.
# rpm metadata now names these URLs directly (see ASSET_BASE in config.sh), so
# dnf fetches the package from here and the count is real.
#
# Add-only, and that is not a detail: GitHub cannot replace an asset in place,
# so re-uploading means deleting first, and the download count dies with the
# asset. A file already up there is left exactly alone.
#
# Run it AFTER make-repo.sh -- that is where packages are signed, and an
# unsigned copy up here would fail gpgcheck on every client -- and BEFORE
# prune.sh, so a version on its way out of the pool is archived rather than
# lost.
#
#   scripts/pool-assets.sh             upload what is missing; skip with no token
#   scripts/pool-assets.sh --require   fail instead of skipping (what CI wants)
set -euo pipefail
source "$(dirname "$0")/config.sh"

require=0
[ "${1:-}" = "--require" ] && require=1

source "$(dirname "$0")/lib-pool.sh"

if [ -z "${pool_token}" ]; then
  [ "${require}" -eq 1 ] && die "no GH_TOKEN or GITHUB_TOKEN in the environment"
  printf '\033[33mwarning:\033[0m no GH_TOKEN or GITHUB_TOKEN; leaving the release assets alone\n' >&2
  exit 0
fi

command -v curl    >/dev/null || die "curl is required to publish the pool assets"
command -v python3 >/dev/null || die "python3 is required to publish the pool assets"

# ------------------------------------------------------------- the release ---
release_id="$(pool_release_id)"

if [ -z "${release_id}" ]; then
  info "creating the ${POOL_TAG} release"
  # make_latest=false, or the pool would outrank a real release on the front
  # page of the repository for ever.
  code="$(gh_api POST "${pool_api}/releases" \
    --header "Content-Type: application/json" \
    --data @- <<JSON
{
  "tag_name": "${POOL_TAG}",
  "name": "${POOL_TITLE}",
  "body": "Every package published by ${REPO_NAME}, kept here rather than in git so that a clone of this repository stays small, and so that GitHub can count what dnf downloads.\n\nThese are the same signed files the repository serves. Install them through the repository rather than by hand:\n\n    curl -fsSL ${BASE_URL}/install.sh | sudo sh",
  "draft": false,
  "prerelease": false,
  "make_latest": "false"
}
JSON
  )"
  [ "${code}" = "201" ] || pool_fail "could not create the ${POOL_TAG} release (HTTP ${code})"
  release_id="$(pool_json 'import json,sys; print(json.load(sys.stdin)["id"])')"
fi

# ------------------------------------------------------- what is up there ---
existing="$(pool_assets "${release_id}" | cut -f1)"
existing="${existing}"$'\n'

# ------------------------------------------------------------- the upload ---
uploaded=0 skipped=0

while IFS= read -r f; do
  [ -n "$f" ] || continue
  name="$(basename "$f")"
  case $'\n'"${existing}" in
    *$'\n'"${name}"$'\n'*) skipped=$(( skipped + 1 )); continue ;;
  esac

  info "uploading ${name} ($(du -h "$f" | cut -f1))"
  code="$(gh_api POST "${pool_uploads}/releases/${release_id}/assets?name=${name}" \
          --header "Content-Type: application/octet-stream" \
          --data-binary "@${f}")"
  [ "${code}" = "201" ] || pool_fail "upload of ${name} failed (HTTP ${code})"
  uploaded=$(( uploaded + 1 ))
done < <(pool_artefacts)

info "pool assets: ${uploaded} uploaded, ${skipped} already published"

# ------------------------------------------------------------- the metadata --
# apt's flat index and pacman's database. Unlike a package these describe the
# pool as it stands, so they are replaced rather than added to -- and replacing
# means deleting first, because GitHub cannot overwrite an asset in place.
#
# Whether they need replacing at all is decided without downloading them: each
# one is uploaded with its own sha256 in the asset's `label`, which the API
# hands back for free. Fetching the old copy to compare would have counted as a
# download of it, on a release whose whole point is that its counters mean
# something.
if [ ! -d "${POOL_META_DIR}" ]; then
  info "no pool metadata staged; apt and pacman keep reading from Pages"
  exit 0
fi

declare -A meta_id=() meta_label=()
while IFS=$'\t' read -r name id; do
  [ -n "${name}" ] || continue
  meta_id["${name}"]="${id}"
done < <(pool_asset_ids "${release_id}")

while IFS=$'\t' read -r name label; do
  [ -n "${name}" ] || continue
  meta_label["${name}"]="${label}"
done < <(pool_asset_labels "${release_id}")

replaced=0 unchanged=0
while IFS= read -r name; do
  src="${POOL_META_DIR}/${name}"
  [ -f "${src}" ] || continue
  sum="sha256:$(sha256sum "${src}" | cut -d' ' -f1)"

  if [ "${meta_label["${name}"]:-}" = "${sum}" ]; then
    unchanged=$(( unchanged + 1 ))
    continue
  fi

  # Delete then upload, in that order and back to back: for the second in
  # between, a client updating right now gets a 404 on this one file and
  # retries. Publishes are rare and the alternative is an index that disagrees
  # with the pool, which is silent and lasts until the next one.
  if [ -n "${meta_id["${name}"]:-}" ]; then
    code="$(gh_api DELETE "${pool_api}/releases/assets/${meta_id["${name}"]}")"
    case "${code}" in
      204|404) ;;
      *) pool_fail "could not delete the old ${name} (HTTP ${code})" ;;
    esac
  fi

  info "publishing ${name} ($(du -h "${src}" | cut -f1))"
  code="$(gh_api POST "${pool_uploads}/releases/${release_id}/assets?name=${name}&label=${sum}" \
          --header "Content-Type: application/octet-stream" \
          --data-binary "@${src}")"
  [ "${code}" = "201" ] || pool_fail "upload of ${name} failed (HTTP ${code})"
  replaced=$(( replaced + 1 ))
done < <(pool_metadata_names)

info "pool metadata: ${replaced} republished, ${unchanged} unchanged"
