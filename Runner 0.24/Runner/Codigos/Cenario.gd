extends ParallaxBackground

@onready var fundo_0: ParallaxLayer = $"Fundo 0"
@onready var fundo_1: ParallaxLayer = $"Fundo 1"
@onready var fundo_3: ParallaxLayer = $"Fundo 3"
@onready var fundo_4: ParallaxLayer = $"Fundo 4"
@onready var fundo_5: ParallaxLayer = $"Fundo 5"
@onready var fundo_6: ParallaxLayer = $"Fundo 6"


@export var speed_fundo0 = 0.2
@export var speed_fundo1 = 0.1
@export var speed_fundo2 = 5

 

var movendo = true

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if movendo:
		fundo_0.motion_offset -= Vector2(speed_fundo0, 0)
		fundo_1.motion_offset -= Vector2(speed_fundo1, 0)
		fundo_3.motion_offset -= Vector2(speed_fundo2, 0)
		fundo_4.motion_offset -= Vector2(speed_fundo2, 0)
		fundo_5.motion_offset -= Vector2(speed_fundo2, 0)
		fundo_6.motion_offset -= Vector2(speed_fundo2, 0)
