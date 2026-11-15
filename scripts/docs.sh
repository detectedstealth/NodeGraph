#!/usr/bin/env bash
# DocC for packages that have a catalog (see docs/TUTORIALS.md).
#   scripts/docs.sh preview [Package]   Live preview (default: NodeGraphTutorials)
#   scripts/docs.sh build               Build every catalog, warnings are errors
#   scripts/docs.sh site                Static-hosting output for GitHub Pages in .docs-site/
set -euo pipefail
cd "$(dirname "$0")/.."

# Packages with a .docc catalog, and the targets inside them.
PACKAGES=(NodeGraphCore NodeGraphTutorials)

case "${1:-build}" in
preview)
    pkg="${2:-NodeGraphTutorials}"
    swift package --package-path "Packages/$pkg" --disable-sandbox preview-documentation --target "$pkg"
    ;;
build)
    for pkg in "${PACKAGES[@]}"; do
        echo "==> docc $pkg"
        swift package --package-path "Packages/$pkg" generate-documentation --target "$pkg" --warnings-as-errors
    done
    ;;
site)
    # GitHub Pages serves a project at https://<user>.github.io/<repository>/, so the repository
    # name is the base path. Set DOCS_BASE_PATH if the repository is not called NodeGraph.
    base="${DOCS_BASE_PATH:-NodeGraph}"
    out="$PWD/.docs-site"
    rm -rf "$out"
    mkdir -p "$out"
    for pkg in "${PACKAGES[@]}"; do
        echo "==> docc site $pkg"
        swift package --package-path "Packages/$pkg" --allow-writing-to-directory "$out/$pkg" \
            generate-documentation --target "$pkg" --disable-indexing \
            --transform-for-static-hosting --hosting-base-path "$base/$pkg" \
            --output-path "$out/$pkg"
    done
    # A front page that points at the tutorials first.
    cat > "$out/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<title>NodeGraph</title>
<h1>NodeGraph</h1>
<ul>
  <li><a href="NodeGraphTutorials/tutorials/nodegraph/">Tutorials</a></li>
  <li><a href="NodeGraphCore/documentation/nodegraphcore/">NodeGraphCore reference</a></li>
</ul>
HTML
    echo "Site written to $out"
    ;;
*)
    echo "usage: $0 preview [Package] | build | site" >&2
    exit 2
    ;;
esac
