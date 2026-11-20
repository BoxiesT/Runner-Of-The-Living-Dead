extends CharacterBody2D

@onready var vidas: Control = $"../../Hud/Vidas"


@onready var chão_inferior: CollisionShape2D = $"../Limites/Lane1/CollisionShape2D"
@onready var chão_superior: CollisionShape2D = $"../Limites/Lane2/CollisionShape2D"



const SPEED = 300.0
const JUMP_VELOCITY = -600.0

const JUMP_BUFFER: float = 0.15
var jump_buffer: float = 0.0


var vida: int = 3

#moedas
@export var moscas: int = 0

#Lanes
var lane_atual: int = 1
var lane_superior: float = 450.0
var lane_inferior: float = 540.0

#troca de lane
var velocidade_troca: float = 0.20
var tween_lane: Tween
var trocando_lane: bool = false

#Shake de dano 
var shake_intensidade: float = 8.0
var shake_duracao: float = 0.15
var tween_shake: Tween


func _ready() -> void:
	atualizar_colisoes_lane()

func _physics_process(delta: float) -> void:
	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

		# Jump com buffer
	if Input.is_action_just_pressed("pulo"):
		jump_buffer = JUMP_BUFFER
	else:
		jump_buffer -= delta
		
	if is_on_floor() and jump_buffer > 0:
		velocity.y = JUMP_VELOCITY
		jump_buffer = 0

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var direction := Input.get_axis("move_left", "move_right")
	
	#Aplica o movimento
	if direction:
		velocity.x = direction * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)

	move_and_slide()
	
	# Troca de lanes
	if Input.is_action_just_pressed("lane_superior"):
		trocar_lane(0)
		
	elif Input.is_action_just_pressed("lane_inferior"):
		trocar_lane(1)


func tomar_dano() -> void:
		vida -= 1 
		print ("Vida atual:", vida)
		shake_dano()
		vidas.atualizar_vida(vida)

		if  vida<= 0:
			morrer()
	
func morrer() -> void:
		print("Bizum Morreu!")	
		get_tree().change_scene_to_file("res://Cenas/Menu.tscn")

#Shake de dano 
func shake_dano() -> void:
	if tween_shake and tween_shake.is_running():
		tween_shake.kill()
	
	var posicao_original = position
	tween_shake = create_tween()


	# Faz pequenos movimentos aleatórios
	for i in range(4):
		var deslocamento = Vector2(
			randf_range(-shake_intensidade, shake_intensidade),
			randf_range(-shake_intensidade, shake_intensidade)
			)
		tween_shake.tween_property(
			self,
	   		"position",
			posicao_original + deslocamento,
			shake_duracao / 4
			)
				
	tween_shake.tween_property(
		self,
		"position",
		posicao_original,
		shake_duracao / 4
	)

# Lanes
func trocar_lane (nova_lane: int) -> void:
	if lane_atual == nova_lane:
		return
	
	if not is_on_floor():
		return
		
	if trocando_lane:
		return
	
	lane_atual = nova_lane
	trocando_lane = true
	atualizar_colisoes_lane()
	var destino_y: float
	
	if lane_atual == 0:
		destino_y = lane_superior
	else:
		destino_y = lane_inferior
	
	velocity.y = 0
	jump_buffer = 0
	
	#animação de troca
	tween_lane = create_tween()
	
	tween_lane.set_trans(Tween.TRANS_SINE)
	tween_lane.set_ease(Tween.EASE_IN_OUT)
	
	tween_lane.tween_property(
		self,
		"position:y",
		destino_y,
		velocidade_troca
	)
	tween_lane.finished.connect(
		func():
			trocando_lane = false
			)

func atualizar_colisoes_lane() -> void:
	chão_superior.disabled = lane_atual != 0
	chão_inferior.disabled = lane_atual != 1

#Cura do player
func _on_bt_curar_pressed() -> void:
	vida = 3
	vidas.atualizar_vida(vida)

#diminui as moedas na compra
func gastar_moscas(valor):
	moscas -= valor
	print("dinhero atual: " + str(moscas))
