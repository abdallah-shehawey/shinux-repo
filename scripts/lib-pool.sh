#!/usr/bin/env bash
# Shared by the scripts that move packages between docs/ and the release assets.
#
# The pool -- every built .rpm, .deb and .pkg.tar.zst -- is not in git any more.
# It lives in the assets of the "pool" release, and docs/ is assembled from it
# at publish time and shipped to Pages as an artifact. That keeps a clone of
# this repository small while the published URLs stay exactly what every
# installed client already has.
#
# Nothing here runs on its own; source it after config.sh.

# ---------------------------------------------------------------- naming ----
# Where make-repo.sh files a .deb, given only its name. apt does not care what
# the pool layout is -- Packages carries the path -- but it has to be the same
# path on the way back in as on the way out, or the pool grows a second copy.
deb_pool_path() {
  local name="$1" pkg letter
  pkg="${name%%_*}"
  case "$pkg" in lib*) letter="${pkg:0:4}" ;; *) letter="${pkg:0:1}" ;; esac
  printf '%s/pool/%s/%s/%s/%s' "${DEB_DIR}" "${DEB_COMPONENT}" "${letter}" "${pkg}" "${name}"
}

# The package name out of an arch filename, and nothing for a file that is not
# a version of anything: make-repo.sh drops an unversioned alias
# (whatsapp-desktop.pkg.tar.zst) next to every small package so `pacman -U
# <url>` works without the repository, and that alias is a copy of the newest
# build rather than a version of its own. The test -- a numeric pkgrel field --
# is the same one is_versioned() uses in gen-pacman-repo.py, and it has to stay
# that way: the two read the same directory.
arch_version_name() {
  local stem="${1##*/}"
  stem="${stem%.sig}"
  stem="${stem%.pkg.tar.zst}"
  local without_arch="${stem%-*}"          # name-version-pkgrel
  local rel="${without_arch##*-}"          # pkgrel
  local name_version="${without_arch%-*}"  # name-version
  case "$rel" in
    ''|*[!0-9]*) return 1 ;;               # no pkgrel: an alias, not a version
  esac
  [ "$name_version" != "$without_arch" ] || return 1
  case "$name_version" in
    *[0-9]*) ;;
    *) return 1 ;;
  esac
  printf '%s' "${name_version%-*}"
}

# The package name out of an rpm or deb filename. Both are strict enough to
# read without opening the file, which is the point: the asset list gives names
# and nothing else.
rpm_file_name() {                          # name-version-release.arch.rpm
  local stem="${1##*/}"; stem="${stem%.rpm}"
  local nvr="${stem%.*}"                   # drop .arch
  local nv="${nvr%-*}"                     # drop -release
  [ "$nv" != "$nvr" ] || return 1
  local name="${nv%-*}"                    # drop -version
  [ "$name" != "$nv" ] || return 1
  printf '%s' "$name"
}

deb_file_name() {                          # name_version_arch.deb
  local stem="${1##*/}"
  [ "${stem%_*}" != "$stem" ] || return 1
  printf '%s' "${stem%%_*}"
}

# Every artefact in docs/ that belongs in the release, newline separated.
# Aliases are left out on purpose: an asset cannot be replaced in place, so an
# alias uploaded once would still name the version it aliased back then.
pool_artefacts() {
  shopt -s nullglob
  local f
  for f in "${RPM_DIR}"/*.rpm;                       do printf '%s\n' "$f"; done
  for f in "${DEB_DIR}"/pool/*/*/*/*.deb;            do printf '%s\n' "$f"; done
  for f in "${ARCH_DIR}"/*.pkg.tar.zst;              do
    arch_version_name "$f" >/dev/null || continue
    printf '%s\n' "$f"
    [ -f "${f}.sig" ] && printf '%s\n' "${f}.sig"
  done
}

# The metadata assets: what apt and pacman read from github.com so that the
# package they fetch next is an asset GitHub counts. Fixed names, because both
# clients ask for these exact ones off the single URL they are configured with.
#
# These are the one thing in the release that is REPLACED rather than added to.
# A package asset is immutable on purpose -- re-uploading means deleting first,
# and the download count dies with the asset -- but an index that still
# describes last month's pool is worse than useless, so these are deleted and
# re-uploaded whenever their bytes change. The counter on an index is not a
# number anybody wants.
pool_metadata_names() {
  printf '%s\n' Packages Packages.gz Release Release.gpg InRelease \
                 "${REPO_ID}.db" "${REPO_ID}.db.sig" \
                 "${REPO_ID}.files" "${REPO_ID}.files.sig"
}

pool_is_metadata() {
  local name="$1" m
  while IFS= read -r m; do [ "$m" = "$name" ] && return 0; done < <(pool_metadata_names)
  return 1
}

# Where an asset goes when it comes back down.
asset_destination() {
  local name="$1"
  case "$name" in
    *.rpm)               printf '%s/%s' "${RPM_DIR}" "$name" ;;
    *.deb)               deb_pool_path "$name" ;;
    *.pkg.tar.zst|*.pkg.tar.zst.sig) printf '%s/%s' "${ARCH_DIR}" "$name" ;;
    *) return 1 ;;
  esac
}

# "<name>\t<id>" per asset. Deleting one needs its id, which the download URL
# does not carry.
pool_asset_ids() {
  local id="$1" page=1 code chunk
  while :; do
    code="$(gh_api GET "${pool_api}/releases/${id}/assets?per_page=100&page=${page}")"
    [ "${code}" = "200" ] || pool_fail "could not list the release assets (HTTP ${code})"
    chunk="$(pool_json 'import json,sys
for a in json.load(sys.stdin):
    print(a["name"], a["id"], sep="\t")')"
    [ -n "${chunk}" ] || break
    printf '%s\n' "${chunk}"
    page=$(( page + 1 ))
  done
}

# "<name>\t<size in bytes>\t<download count>" per asset. pool-notes.sh prints
# both beside every download link, and the API hands them over with the listing
# -- reading the size off the file would mean fetching the file, and moving the
# very counter printed next to it, on a release whose counters are the whole
# reason the packages are up here.
pool_asset_stats() {
  local id="$1" page=1 code chunk
  while :; do
    code="$(gh_api GET "${pool_api}/releases/${id}/assets?per_page=100&page=${page}")"
    [ "${code}" = "200" ] || pool_fail "could not list the release assets (HTTP ${code})"
    chunk="$(pool_json 'import json,sys
for a in json.load(sys.stdin):
    print(a["name"], a["size"], a["download_count"], sep="\t")')"
    [ -n "${chunk}" ] || break
    printf '%s\n' "${chunk}"
    page=$(( page + 1 ))
  done
}

# "<name>\t<label>" per asset. pool-assets.sh writes each metadata asset's own
# sha256 into its label, so a later run can tell whether the bytes changed
# without downloading the copy that is up there -- which would have counted as
# a download of it.
pool_asset_labels() {
  local id="$1" page=1 code chunk
  while :; do
    code="$(gh_api GET "${pool_api}/releases/${id}/assets?per_page=100&page=${page}")"
    [ "${code}" = "200" ] || pool_fail "could not list the release assets (HTTP ${code})"
    chunk="$(pool_json 'import json,sys
for a in json.load(sys.stdin):
    print(a["name"], a.get("label") or "", sep="\t")')"
    [ -n "${chunk}" ] || break
    printf '%s\n' "${chunk}"
    page=$(( page + 1 ))
  done
}

# The package an asset is a version of, so the newest few can be picked without
# downloading any of them.
asset_package() {
  local name="$1"
  case "$name" in
    *.rpm)                           rpm_file_name  "$name" ;;
    *.deb)                           deb_file_name  "$name" ;;
    *.pkg.tar.zst|*.pkg.tar.zst.sig) arch_version_name "$name" ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------ API -----
# GITHUB_API_URL is set by Actions itself; both are overridable so the flow can
# be exercised against a stub instead of against the real release.
pool_api="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_USER}/${GITHUB_REPO}"
pool_uploads="${GITHUB_UPLOADS_URL:-https://uploads.github.com}/repos/${GITHUB_USER}/${GITHUB_REPO}"
pool_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

# Every call writes its response to ${pool_body} and prints the status code, so
# a failure can say what GitHub actually complained about instead of "exit 22".
# A named path rather than mktemp, because gh_api is called from inside command
# substitutions -- a temporary file created there belongs to a subshell, and
# the reader in the parent would find the variable still empty. curl creates
# it; the callers that never touch the API just carry an unused trap.
pool_body="${TMPDIR:-/tmp}/shinux-pool-response-$$"
trap 'rm -f "${pool_body}"' EXIT

gh_api() {
  local method="$1" url="$2"; shift 2
  curl --silent --show-error --location \
       --request "${method}" --output "${pool_body}" --write-out '%{http_code}' \
       --header "Authorization: Bearer ${pool_token}" \
       --header "Accept: application/vnd.github+json" \
       --header "X-GitHub-Api-Version: 2022-11-28" \
       "$@" "${url}"
}

pool_json() { python3 -c "$1" < "${pool_body}"; }

pool_fail() {
  printf '\033[31merror:\033[0m %s\n' "$1" >&2
  sed -n '1,20p' "${pool_body}" >&2
  exit 1
}

# Prints the release id, or nothing at all when the release does not exist yet.
pool_release_id() {
  local code; code="$(gh_api GET "${pool_api}/releases/tags/${POOL_TAG}")"
  case "${code}" in
    200) pool_json 'import json,sys; print(json.load(sys.stdin)["id"])' ;;
    404) return 0 ;;
    *)   pool_fail "could not read the ${POOL_TAG} release (HTTP ${code})" ;;
  esac
}

# "<name>\t<download url>" per asset. Paginated: the pool outgrows one page of
# 100 after enough versions, and a short read would look like a pool with
# holes in it -- assets re-uploaded, packages re-downloaded.
pool_assets() {
  local id="$1" page=1 code chunk
  while :; do
    code="$(gh_api GET "${pool_api}/releases/${id}/assets?per_page=100&page=${page}")"
    [ "${code}" = "200" ] || pool_fail "could not list the release assets (HTTP ${code})"
    chunk="$(pool_json 'import json,sys
for a in json.load(sys.stdin):
    print(a["name"], a["browser_download_url"], sep="\t")')"
    [ -n "${chunk}" ] || break
    printf '%s\n' "${chunk}"
    page=$(( page + 1 ))
  done
}
