extends Node2D

@onready var score_manager: Node = $Score_Manager
@onready var run_manager: Node = $Run_Manager
@onready var player: CharacterBody2D = $Player

var mult_pendente: float = 1.0
	
func _ready() -> void:
	pass
	
func _process(delta: float) -> void:
	score_manager.start_score(delta)
	score_manager.atualizar_label()
	run_manager.add_distance(delta)
	run_manager.atualizar_barra()
	

func iniciar_run():
	player.position = Vector2(100,520)
	
	#Aplicar Itens:
	#Aplicar item - multiplicar score
	score_manager.reset_multiplier()
	if mult_pendente > 1.0:
		score_manager.set_multiplier(mult_pendente)
		score_manager.atualizar_label()
	mult_pendente = 1.0
	
	set_run_distance()
	
func set_run_distance():
	var distancia_sorteada = run_manager.sortear_distancia()
	print("Distancia da RUN: " , distancia_sorteada)
	#run_manager.start_run(distancia_sorteada)
	run_manager.start_run(10)

func limpar_obstaculos() -> void:
	for obstaculo in get_tree().get_nodes_in_group("obstaculos"):
		obstaculo.queue_free()

#mudar multiplicador da run
func adicionar_mult(valor):
	mult_pendente = valor
