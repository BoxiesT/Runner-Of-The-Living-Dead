extends ParallaxBackground

@onready var fundo_0: ParallaxLayer = $"Fundo 0"
@onready var fundo_1: ParallaxLayer = $"Fundo 1"

@export var speed_fundo0 = 0.2
@export var speed_fundo1 = 5

var movendo = true

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if movendo:
		fundo_0.motion_offset -= Vector2(speed_fundo0, 0)
		fundo_1.motion_offset -= Vector2(speed_fundo1, 0)
