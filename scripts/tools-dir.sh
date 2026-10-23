# Sourced by the other scripts/ tools. Resolves a blueprint directory to its
# pinned anofox-visualization tools directory, from <bp>/blueprint.json.
#
#   . "$HERE/tools-dir.sh"
#   tools_dir <blueprint-dir>          -> REPO/.cache/tools/<pin>
#   blueprint_field <bp> <key>         -> blueprint.json[key] (top-level only)
#
# REPO must already be set (the repo root, scripts/ one level below it).

blueprint_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1/blueprint.json" "$2"
}

tools_dir() {
  local bp="$1" ver
  ver="$(blueprint_field "$bp" anofox_visualization)"
  echo "$REPO/.cache/tools/$ver"
}
