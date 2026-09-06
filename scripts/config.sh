#!/usr/bin/env bash
# Shared configuration for every build/publish script in this repository.
# Edit the values in this block and nothing else needs to change.

GITHUB_USER="abdallah-shehawey"
GITHUB_REPO="shinux-repo"

# Keep the package/repository id stable so existing shinux installs continue to
# receive upgrades after the GitHub repository rename.
# Short id used for the .repo file, the apt sources file and the GPG key name.
REPO_ID="shinux"
REPO_NAME="Shinux Repository"

# Public URL that GitHub Pages serves docs/ from. No trailing slash.
BASE_URL="${BASE_URL:-https://${GITHUB_USER}.github.io/${GITHUB_REPO}}"

# Where dnf fetches the packages themselves from. Pages publishes no statistics
# of any kind, so an install that came from `dnf install` was a download nobody
# could see: the counters on the releases page only ever moved for someone who
# clicked a link. Release assets are counted, so the rpms are uploaded there as
# well and primary.xml carries an xml:base pointing at them -- metadata, keys
# and signatures still come from Pages, and no client configuration changes.
POOL_TAG="${POOL_TAG:-pool}"

# What that release is called on the repository's front page. The tag stays
# "pool" for ever -- every package URL ever published has it in the path, and
# rpm metadata on installed machines names it -- but the title is read by
# people only, and "pool" is this repository's word for it, not theirs.
POOL_TITLE="${POOL_TITLE:-Packages}"
ASSET_ROOT="${ASSET_ROOT:-https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/download}"
ASSET_BASE="${ASSET_BASE:-${ASSET_ROOT}/${POOL_TAG}}"

# apt and pacman have no xml:base. Both resolve a package's recorded filename
# against the one URL their client configuration names, so the only way to move
# their downloads onto the counted release is to move the *metadata* there too
# -- which works because a release is a flat namespace and both formats can be
# served flat:
#
#   apt    a "flat repository": `URIs: .../releases/download` with
#          `Suites: pool/` and no Components. apt then fetches
#          .../download/pool/{InRelease,Packages,Packages.gz} -- asset names
#          with no slash in them -- and resolves `Filename:` against the same
#          directory, so a bare `foo_1.0-1_all.deb` is an asset URL.
#   pacman `Server = .../releases/download/pool`. It already asks for
#          `shinux.db` and a bare %FILENAME% off that one base, so nothing but
#          the base changes.
#
# The Pages trees stay exactly where they are and keep working: a machine that
# added the repository before this still reads from them. Clients move over
# when they upgrade shinux-archive-keyring, or re-run install.sh.

# On where those assets exist, off everywhere else. A local `make repo` that
# wrote the asset base into the metadata would send `make serve` and
# `make test` to github.com for packages sitting in the checkout, and would
# name assets that this run has not uploaded.
ASSET_POOL="${ASSET_POOL:-${GITHUB_ACTIONS:+1}}"
ASSET_POOL="${ASSET_POOL:-0}"

# Identity burned into the signing key and into every package's Maintainer field.
MAINTAINER_NAME="Abdallah Shehawey"
MAINTAINER_EMAIL="shehawey9@gmail.com"
GPG_KEY_UID="${REPO_NAME} Signing Key <${MAINTAINER_EMAIL}>"

# Shown by `dnf info` as "Vendor", and by `rpm -qi` as Vendor + Packager. rpm
# leaves both <NULL> unless the spec sets them: distributions define them from
# a macro their build system ships, so a third-party repo has to say it itself.
PACKAGE_VENDOR="${MAINTAINER_NAME}"

# apt architectures the Release file advertises. Packages marked
# "Architecture: all" are folded into each of these automatically.
DEB_ARCHS="amd64 arm64"
DEB_SUITE="stable"
DEB_COMPONENT="main"

# --- derived paths, do not edit -------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build}"
POOL_META_DIR="${POOL_META_DIR:-${BUILD_DIR}/pool-meta}"   # flat apt+pacman metadata, uploaded as assets
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/docs}"   # published by GitHub Pages (main branch, /docs)
RPM_DIR="${OUT_DIR}/rpm"
DEB_DIR="${OUT_DIR}/deb"
ARCH_DIR="${OUT_DIR}/arch"
KEY_ASC="${OUT_DIR}/RPM-GPG-KEY-${REPO_ID}"   # armored, used by rpm/dnf
KEY_GPG="${OUT_DIR}/${REPO_ID}.gpg"           # dearmored, used by apt signed-by
GNUPGHOME_DIR="${ROOT_DIR}/.gnupg"

export GITHUB_USER GITHUB_REPO REPO_ID REPO_NAME BASE_URL \
       POOL_TAG POOL_TITLE ASSET_ROOT ASSET_BASE ASSET_POOL POOL_META_DIR \
       MAINTAINER_NAME MAINTAINER_EMAIL GPG_KEY_UID PACKAGE_VENDOR \
       DEB_ARCHS DEB_SUITE DEB_COMPONENT \
       ROOT_DIR BUILD_DIR OUT_DIR RPM_DIR DEB_DIR ARCH_DIR KEY_ASC KEY_GPG GNUPGHOME_DIR

# Resolve the signing key fingerprint, if a key exists at all.
gpg_fpr() {
  local home="${GNUPGHOME_DIR}"
  [ -n "${SIGN_GNUPGHOME:-}" ] && home="${SIGN_GNUPGHOME}"
  [ -d "$home" ] || return 1
  GNUPGHOME="$home" gpg --list-secret-keys --with-colons "${GPG_KEY_UID}" 2>/dev/null \
    | awk -F: '/^fpr:/ {print $10; exit}'
}

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
