#!/bin/bash
# Builds a throw-away Godot project with the addon + the test driver enabled.
#   usage: make_proj.sh <dest_dir> [addons_dir]      (env: GODOT=/path/to/godot)
HERE="$(cd "$(dirname "$0")" && pwd)"
GODOT="${GODOT:-godot}"
DEST="$1"; ADDONS="${2:-$(cd "$HERE/../../.." && pwd)}"
[ -z "$DEST" ] && { echo "usage: make_proj.sh <dest_dir> [addons_dir]"; exit 1; }
rm -rf "$DEST"; mkdir -p "$DEST/addons"
cp -r "$ADDONS/godot_live_collab" "$DEST/addons/"
rm -rf "$DEST/addons/godot_live_collab/tests/integration"   # not needed inside the test project
cp -r "$HERE/driver/addons/glc_driver" "$DEST/addons/"
cat > "$DEST/project.godot" <<'EOP'
; Engine configuration file.
config_version=5

[application]
config/name="GLC Test"
config/features=PackedStringArray("4.7")

[editor_plugins]
enabled=PackedStringArray("res://addons/godot_live_collab/plugin.cfg", "res://addons/glc_driver/plugin.cfg")
EOP
"$HERE/reset_proj.sh" "$DEST"
# first start imports the project (class cache, uid files); both test instances then start from the same state
( cd "$DEST" && timeout 90 "$GODOT" --headless --editor --path . --quit-after 60 >/dev/null 2>&1 )
