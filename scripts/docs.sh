#!/usr/bin/env bash
# DocC for targets that have a catalog (see docs/TUTORIALS.md).
#   scripts/docs.sh preview [Target]    Live preview (default: NodeGraphTutorials)
#   scripts/docs.sh build               Build every catalog, warnings are errors
#   scripts/docs.sh site                Static-hosting output for GitHub Pages in .docs-site/
set -euo pipefail
cd "$(dirname "$0")/.."

# Targets with a .docc catalog.
PACKAGES=(NodeGraphCore NodeGraphTutorials)

case "${1:-build}" in
preview)
    pkg="${2:-NodeGraphTutorials}"
    swift package --disable-sandbox preview-documentation --target "$pkg"
    ;;
build)
    for pkg in "${PACKAGES[@]}"; do
        echo "==> docc $pkg"
        swift package generate-documentation --target "$pkg" --warnings-as-errors
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
        swift package --allow-writing-to-directory "$out/$pkg" \
            generate-documentation --target "$pkg" --disable-indexing \
            --transform-for-static-hosting --hosting-base-path "$base/$pkg" \
            --output-path "$out/$pkg"
    done
    # A front page that points at the tutorials first. Quoted heredoc: nothing in it is expanded.
    mkdir -p "$out/images"
    cp docs/images/editor-macos.png docs/images/editor-ipad.png "$out/images/"
    cat > "$out/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NodeGraph: a node graph system for Swift</title>
<meta name="description" content="A general-purpose node graph system in Swift: core, built-in nodes, a SwiftUI editor for macOS and iPadOS, a headless runner for Linux, and a graph assistant.">
<style>
  :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #ffffff; --card: #f5f5f7; --accent: #0a66c2; }
  @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --bg: #161618; --card: #232326; --accent: #5aa9f7; } }
  body { margin: 0; font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; color: var(--fg); background: var(--bg); }
  main { max-width: 860px; margin: 0 auto; padding: 56px 24px 72px; }
  h1 { font-size: 2.6rem; margin: 0 0 8px; letter-spacing: -0.02em; }
  .lead { font-size: 1.2rem; color: var(--muted); margin: 0 0 32px; }
  a { color: var(--accent); }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; margin: 0 0 40px; }
  .card { background: var(--card); border-radius: 14px; padding: 20px; text-decoration: none; color: inherit; display: block; }
  .card strong { display: block; font-size: 1.1rem; margin-bottom: 4px; color: var(--accent); }
  .card span { color: var(--muted); font-size: 0.95rem; }
  figure { margin: 0 0 24px; }
  figure img { width: 100%; height: auto; border-radius: 12px; display: block; }
  figcaption { color: var(--muted); font-size: 0.9rem; margin-top: 8px; }
  h2 { font-size: 1.4rem; margin: 40px 0 12px; }
  ul { padding-left: 1.2rem; }
  footer { margin-top: 48px; color: var(--muted); font-size: 0.9rem; }
</style>
</head>
<body>
<main>
  <h1>NodeGraph</h1>
  <p class="lead">A general-purpose node graph system in Swift, for many domains: robotics scenarios, video editing, and your own.</p>

  <div class="cards">
    <a class="card" href="NodeGraphTutorials/tutorials/nodegraph/">
      <strong>Tutorials</strong>
      <span>From an empty graph to your own node pack: build, run, save and show a graph, then the robotics and video packs, headless runs and the assistant.</span>
    </a>
    <a class="card" href="NodeGraphCore/documentation/nodegraphcore/">
      <strong>NodeGraphCore reference</strong>
      <span>The API of the core: graphs, commands and undo, execution, serialization, subgraphs.</span>
    </a>
    <a class="card" href="https://github.com/detectedstealth/NodeGraph">
      <strong>Source on GitHub</strong>
      <span>Apache-2.0. Swift 6.3 or later; macOS 26 and iOS 26 for the editor, Linux for the core and runner.</span>
    </a>
  </div>

  <figure>
    <img src="images/editor-macos.png" alt="The NodeGraph editor on macOS: a robotics temperature pipeline in three groups, the console, and the assistant panel">
    <figcaption>The editor on macOS.</figcaption>
  </figure>
  <figure>
    <img src="images/editor-ipad.png" alt="The same editor on iPad, with the minimap, console and assistant panel">
    <figcaption>The same editor on iPad.</figcaption>
  </figure>

  <h2>What is in it</h2>
  <ul>
    <li><strong>Core:</strong> graph model, commands with undo and redo, a validated execution engine, subgraphs and a JSON file format. No UI imports; it also builds on Linux.</li>
    <li><strong>Nodes and packs:</strong> built-in math, logic, string, flow and data nodes, plus robotics and video packs. Write your own pack against the core alone.</li>
    <li><strong>Editor:</strong> a SwiftUI canvas editor for macOS and iPadOS, with an inspector, a console and a minimap.</li>
    <li><strong>Headless runner:</strong> <code>ng-run</code> runs a saved graph from a shell, on macOS or Linux.</li>
    <li><strong>Graph assistant:</strong> deterministic analysis plus a model that proposes changes you review before anything is applied.</li>
  </ul>

  <footer>Copyright 2026 Bruce Wade. Licensed under Apache-2.0.</footer>
</main>
</body>
</html>
HTML
    echo "Site written to $out"
    ;;
*)
    echo "usage: $0 preview [Target] | build | site" >&2
    exit 2
    ;;
esac
