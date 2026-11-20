#!/bin/bash
# Restores the pristine test files (the editor saves open scripts when it quits).
P="$1"
cat > "$P/main.tscn" <<'EOS'
[gd_scene format=3]

[node name="Main" type="Node2D"]

[node name="Player" type="Sprite2D" parent="."]
position = Vector2(10, 20)

[node name="UI" type="Control" parent="."]
layout_mode = 3
anchors_preset = 0
EOS
cat > "$P/player.gd" <<'EOS'
extends Node2D

var speed := 10

func _ready():
	print(speed)
EOS
rm -rf "$P/res_extra" "$P/.glc_backup" "$P/shared" "$P/live" "$P/emptydir" "$P/client_only.txt" "$P/from_client.txt" "$P/.godot/glc_manifest_cache.json" "$P/other.tscn" "$P/enemy.tscn" "$P/scripts" "$P/art" "$P/levels" "$P/empty_folder" "$P/game.gd" "$P/game.gd.uid" "$P/.godot/editor/editor_layout.cfg"
