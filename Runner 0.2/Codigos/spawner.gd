extends Node2D

@export var cena_obstaculo: PackedScene

@export var lista_obstaculos: Array[ PackedScene] = []

@export var tempo_minimo: float = 2.0
@export var tempo_maximo: float = 5.0

@onready var timer: Timer = $Timer


func _ready() -> void:
	definir_proximo_tempo()
	
func _on_timer_timeout() -> void:
	if lista_obstaculos.size() > 0: 
		var cena_sorteada = lista_obstaculos.pick_random()
		
		if cena_sorteada != null:
			var novo_obstaculo= cena_sorteada.instantiate() 
			novo_obstaculo.position = global_position
			get_parent().add_child(novo_obstaculo)
		
		definir_proximo_tempo()

func definir_proximo_tempo() -> void:
	var tempo_sorteado = randf_range(tempo_minimo, tempo_maximo)
	timer.wait_time = tempo_sorteado
	timer.start()
