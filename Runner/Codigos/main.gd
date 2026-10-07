extends Node2D

@onready var mapa: Map = $Mapa
@onready var run: Node2D = $Run
@onready var cenario: ParallaxBackground = $Run/Cenario
@onready var pause_menu: CanvasLayer = $PauseMenu

@onready var loja: Control = $Loja
@onready var cura: Control = $Cura
@onready var boss: Control = $Boss



enum Secao {
	MAPA = 0,
	RUN = 1,
	LOJA = 2,
	CURA = 3,
	BOSS = 4,
	
}

var primeira_run = true

var jogo_pausado := false
var Fim = false

func _ready() -> void:
	pause_menu.visible = false
	mapa.generate_new_map()
	mapa.unlock_floor(0)
	mudar_secao(Secao.RUN)
	
	#mapa.unlock_next_rooms()
	
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		alternar_pausa()

func alternar_pausa():
	jogo_pausado = !jogo_pausado
	get_tree().paused = jogo_pausado
	if !Fim:
		pause_menu.visible = jogo_pausado


func _on_mapa_room_selected(room) -> void:
	var secao: Secao = room as Secao
	mudar_secao(secao)
	
func _on_bt_sair_pressed() -> void:
	mudar_secao(Secao.MAPA)
	

func mudar_secao(nova_secao:Secao):
	
	var secao_atual = nova_secao
	run.hide()
	cenario.hide()
	
	mapa.hide()
	
	loja.hide()
	
	cura.hide()
	
	boss.hide()
	
	mapa.process_mode = Node.PROCESS_MODE_DISABLED
	run.process_mode = Node.PROCESS_MODE_DISABLED
	loja.process_mode = Node.PROCESS_MODE_DISABLED
	cura.process_mode = Node.PROCESS_MODE_DISABLED
	boss.process_mode = Node.PROCESS_MODE_DISABLED
	
	match nova_secao:
		Secao.MAPA:
			#print("Abrindo Mapa")
			mapa.show()
			mapa.process_mode = Node.PROCESS_MODE_INHERIT
		Secao.RUN:
			#print("Abrindo Run")
			run.show()
			cenario.show()
			run.process_mode = Node.PROCESS_MODE_INHERIT
			if !primeira_run:
				mapa.unlock_next_rooms()
			mapa.reset_camera()
			run.iniciar_run()
			
		Secao.LOJA:
			#print("Abrindo Loja")
			loja.show()
			loja.process_mode = Node.PROCESS_MODE_INHERIT
			if !primeira_run:
				mapa.unlock_next_rooms()
			mapa.reset_camera()
			loja.iniciar_loja()
			
		Secao.CURA:
			#print("Abrindo Cura")
			cura.show()
			cura.process_mode = Node.PROCESS_MODE_INHERIT
			if !primeira_run:
				mapa.unlock_next_rooms()
			mapa.reset_camera()
			cura.iniciar_cura()
			
			
		Secao.BOSS:
			print("Abrindo Boss")
			boss.show()
			boss.process_mode = Node.PROCESS_MODE_INHERIT
			if !primeira_run:
				mapa.unlock_next_rooms()
			mapa.reset_camera()

	
func _run_finished() -> void:
	primeira_run = false
	mudar_secao(Secao.MAPA)


func _on_button_continuar_pressed() -> void:
	jogo_pausado = false
	get_tree().paused = false
	pause_menu.visible = false


func _on_button_menu_pressed() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://Cenas/Menu.tscn")

#Encerramento


func _on_bt_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://Cenas/Menu.tscn")


func _on_bt_replay_pressed() -> void:
	get_tree().change_scene_to_file("res://Cenas/Main.tscn")
