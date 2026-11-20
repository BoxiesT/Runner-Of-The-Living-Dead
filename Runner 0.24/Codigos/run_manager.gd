extends Node

@onready var progress_bar: ProgressBar = $"../../Hud/ProgressBar"

signal run_finished

const distance_per_second: float = 10.0

enum Dificuldade {
	FACIL,
	MEDIO,
	DIFICIL,
}

@export var diciculdade: Dificuldade = Dificuldade.FACIL

var distance := 0.0
var target_distance := 0
var run_ended := true

func sortear_distancia() -> float:
	match  diciculdade:
		Dificuldade.FACIL:
			return randi_range(400.0,800.0)
		Dificuldade.MEDIO:
			return randi_range(900.0,1300.0)
		Dificuldade.DIFICIL:
			return randi_range(1400.0,1800.0)
	return 1000.0
	
func start_run(distance_goal: float) -> void:
	distance = 0.0
	barra_visivel(true)
	target_distance = distance_goal
	run_ended = false

func add_distance(d):
	if run_ended:
		return
	distance += distance_per_second * d
	#print(distance)
	if distance >= target_distance:
		finish_run()

func finish_run():
	if run_ended:
		return
	run_ended = true
	barra_visivel(false)
	run_finished.emit()


#Progress Bar 
func atualizar_barra():
	progress_bar.max_value = target_distance
	progress_bar.value = distance

func barra_visivel(visivel:bool):
	progress_bar.visible = visivel
