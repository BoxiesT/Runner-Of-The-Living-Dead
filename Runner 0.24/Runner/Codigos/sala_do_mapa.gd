class_name MapRoom
extends Area2D

signal selected(room:Room)


const RUN = "res://Artes/Oficial Map Icons/RunIconPrancheta_1.png"
const CURA = "res://Artes/Oficial Map Icons/CuraIconPrancheta_1.png"
const LOJA = "res://Artes/Oficial Map Icons/LojaIconPrancheta_1.png"
const CHEFE = "res://Artes/Oficial Map Icons/BossIconPrancheta_1.png"


# Scale dos Icones

const ICONS := {
	Room.Type.NOT_ASSINED: [null, Vector2.ONE], 
	Room.Type.RUN: [preload(RUN), Vector2(1.0,1.0)],
	Room.Type.HEALTH: [preload(CURA), Vector2(1.0,1.0)],
	Room.Type.SHOP: [preload(LOJA), Vector2(1.0,1.0)],
	Room.Type.BOSS: [preload(CHEFE), Vector2(1.0,1.0)],
}

@onready var sprite_2d: Sprite2D = $Visuals/Sprite2D
@onready var line_2d: Line2D = $Visuals/Line2D
@onready var animation_player: AnimationPlayer = $AnimationPlayer

var available := false : set = set_available
var room: Room : set = set_room


func set_available(new_value:bool) -> void:
	available = new_value
	
	if available:
		animation_player.play("highlight")
	elif not room.selected:
		animation_player.play("RESET")

func set_room(new_data: Room) -> void:
	room = new_data
	position = room.position
	line_2d.rotation_degrees = randi_range(0, 360)
	sprite_2d.texture = ICONS[room.type][0]
	sprite_2d.scale = ICONS[room.type][1]
	
func show_selected() -> void:
	line_2d.modulate = Color.WHITE
	
func _on_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not available or not event.is_action_pressed("left_click"):
		return
	room.selected = true
	animation_player.play('Select')

func _on_map_room_selected() -> void:
	selected.emit(room)
