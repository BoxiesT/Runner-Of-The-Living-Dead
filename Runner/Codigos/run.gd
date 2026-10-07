extends Node2D

@onready var score_manager: Node = $Score_Manager
@onready var run_manager: Node = $Run_Manager
@onready var player: CharacterBody2D = $Player


	
func _ready() -> void:
	pass
	
func _process(delta: float) -> void:
	score_manager.start_score(delta)
	score_manager.atualizar_label()
	run_manager.add_distance(delta)

func iniciar_run():
	player.position = Vector2(100,520)
	set_run_distance()
	
func set_run_distance():
	run_manager.start_run(100)
