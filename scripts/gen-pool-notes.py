#!/usr/bin/env python3
"""Turn the pool release's asset list into an index someone can read.

GitHub sorts a release's attachments alphabetically and offers no way to group
them, so this release -- three package formats of a dozen programs, plus apt's
indexes and pacman's database -- renders as one flat run of a hundred
filenames, every version of every package interleaved with every other. Someone
after the .deb has to know the filename before they can find it.

The description is the one part of a release this repository controls, so the
grouping lives there: a section per package, a list per distribution inside it,
newest first, every entry a direct link. The attachment list underneath is left
exactly as GitHub renders it.

Reads two TSV files -- the asset list, and the summary of each package -- both
collected by pool-notes.sh, and prints markdown on stdout. Nothing here touches
the network: the sizes come from the API listing rather than from the files,
because downloading a package to measure it would move the counter that is the
whole reason the packages are attached here at all.

    gen-pool-notes.py <assets.tsv> <summaries.tsv>
"""
import os
import re
import sys

# What apt and pacman read off this release to find everything else. They are
# attached like any other asset, but they are indexes rather than packages and
# nobody fetches one on purpose, so they get a footnote instead of a section.
METADATA = {
    "Packages", "Packages.gz", "Release", "Release.gpg", "InRelease",
    "{id}.db", "{id}.db.sig", "{id}.files", "{id}.files.sig",
}

# The label each format is filed under, and the command that installs from it.
# Ordered rpm-deb-arch rather than alphabetically: it is the order the rest of
# the repository lists them in, from the maintainer's own distribution outwards.
FORMATS = (
    ("rpm",  "Fedora / RHEL",   "sudo dnf install {pkg}"),
    ("deb",  "Debian / Ubuntu", "sudo apt install {pkg}"),
    ("arch", "Arch Linux",      "sudo pacman -S {pkg}"),
)

# Package name and version straight out of the filename. Every format encodes
# both strictly enough to read without opening the file, which is the point:
# the API hands over names, and opening a package would mean downloading it.
# These mirror rpm_file_name/deb_file_name/arch_version_name in lib-pool.sh --
# the unversioned arch alias make-repo.sh drops beside each small package fails
# the pkgrel group here for the same reason it is skipped there.
PATTERNS = (
    ("rpm",  re.compile(r"^(?P<name>.+)-(?P<ver>[^-]+-[^-]+)\.(?:noarch|x86_64|aarch64)\.rpm$")),
    ("deb",  re.compile(r"^(?P<name>[^_]+)_(?P<ver>[^_]+)_[^_]+\.deb$")),
    ("arch", re.compile(r"^(?P<name>.+)-(?P<ver>[^-]+-[^-]+)-(?:any|x86_64|aarch64)\.pkg\.tar\.zst$")),
)


def version_key(version):
    """Sort 1.6.11-1 above 1.6.9-1, and 2.2.1-2 above 2.2.1-1.

    Each segment becomes a triple whose first element says which kind it is, so
    a numeric segment and an alphabetic one are never compared to each other --
    which is what a bare mix of int and str would do, and it raises rather than
    sorting wrongly.
    """
    return [
        (0, int(part), "") if part.isdigit() else (1, 0, part)
        for part in re.split(r"[.\-_+~]", version)
    ]


def human(size):
    for unit, step in (("GB", 1000 ** 3), ("MB", 1000 ** 2), ("KB", 1000)):
        if size >= step:
            return f"{size / step:.0f} {unit}"
    return f"{size} B"


def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if line:
                rows.append(line.split("\t"))
    return rows


def main():
    repo_id = os.environ.get("REPO_ID", "shinux")
    repo_name = os.environ.get("REPO_NAME", "Shinux Repository")
    base_url = os.environ.get("BASE_URL", "")
    metadata = {name.format(id=repo_id) for name in METADATA}

    assets = {name: (url, int(size)) for name, url, size in read_tsv(sys.argv[1])}
    summaries = dict(read_tsv(sys.argv[2])) if len(sys.argv) > 2 else {}

    # name -> format -> [(sort key, version, filename)]
    packages = {}
    signatures = 0
    for name in assets:
        if name in metadata:
            continue
        if name.endswith(".sig"):
            signatures += 1
            continue
        for fmt, pattern in PATTERNS:
            match = pattern.match(name)
            if match:
                packages.setdefault(match["name"], {}).setdefault(fmt, []).append(
                    (version_key(match["ver"]), match["ver"], name)
                )
                break

    out = []
    add = out.append

    add(f"Every package published by {repo_name}, kept here rather than in git "
        "so that a clone of the repository stays small, and so that GitHub can "
        "count what `dnf` downloads.")
    add("")
    add("Nothing below has to be fetched by hand. Add the repository once and "
        "the package manager takes it from there:")
    add("")
    add(f"    curl -fsSL {base_url}/install.sh | sudo sh")
    add("")
    add("The index below is those same attachments, grouped: a section per "
        "package, a list per distribution inside it, newest first. GitHub "
        "sorts the attachment list itself alphabetically and cannot group it, "
        "which is the only reason this index exists.")
    add("")

    names = sorted(packages)
    add("**Jump to:** " + " · ".join(f"[{n}](#{n})" for n in names))
    add("")

    for name in names:
        by_format = packages[name]
        add("---")
        add("")
        add(f"## {name}")
        add("")
        if summaries.get(name):
            add(summaries[name])
            add("")

        installs = [
            f"`{command.format(pkg=name)}`"
            for fmt, _, command in FORMATS
            if fmt in by_format
        ]
        add("**Install:** " + " · ".join(installs))
        add("")

        for fmt, label, _ in FORMATS:
            builds = by_format.get(fmt)
            if not builds:
                continue
            add(f"### {name} for {label}")
            add("")
            builds.sort(key=lambda build: build[0], reverse=True)
            for index, (_, version, filename) in enumerate(builds):
                url, size = assets[filename]
                newest = " — **newest**" if index == 0 else ""
                add(f"- `{version}` · [{filename}]({url}) · {human(size)}{newest}")
            add("")

    add("---")
    add("")
    add("### What the rest of the attachments are")
    add("")
    add(f"`Packages`, `Packages.gz`, `InRelease`, `Release`, `Release.gpg`, "
        f"`{repo_id}.db` and `{repo_id}.files` are the indexes apt and pacman "
        "read off this release to find the packages above. They are attached "
        "for those clients, not for people.")
    if signatures:
        add("")
        add(f"The {signatures} `.sig` files are detached signatures. pacman "
            "checks one for every package it installs, so each has to be "
            "reachable from the same base URL as the package it signs.")

    body = "\n".join(out) + "\n"

    # A release description is capped at 125,000 characters, and going over it
    # is an HTTP 422 on a step that runs at the end of a publish -- after the
    # packages are already uploaded. Failing here, with the number, beats
    # failing there with a validation error.
    if len(body) > 120_000:
        sys.exit(f"error: the description is {len(body)} characters, too close "
                 "to GitHub's 125,000 limit; prune the pool")

    sys.stdout.write(body)


if __name__ == "__main__":
    main()
