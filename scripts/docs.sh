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
    for pkg in "${PACKAGES[@]}"; do
        echo "==> docc site $pkg"
        swift package --package-path "Packages/$pkg" --allow-writing-to-directory ".docs-site/$pkg" \
            generate-documentation --target "$pkg" --disable-indexing \
            --transform-for-static-hosting --hosting-base-path "NodeGraph/$pkg" \
            --output-path ".docs-site/$pkg"
    done
    ;;
*)
    echo "usage: $0 preview [Package] | build | site" >&2
    exit 2
    ;;
esac
