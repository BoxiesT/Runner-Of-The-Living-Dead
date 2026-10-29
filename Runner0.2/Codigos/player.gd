extends CharacterBody2D

@onready var vidas: Control = $"../../Hud/Vidas"

const SPEED = 300.0
const JUMP_VELOCITY = -600.0

const JUMP_BUFFER: float = 0.15
var jump_buffer: float = 0.0


var vida: int = 3


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

func tomar_dano() -> void:
		vida -= 1 
		print ("Vida atual:", vida)
		vidas.atualizar_vida(vida)

		if  vida<= 0:
			morrer()
	
func morrer() -> void:
		print("Bizum Morreu!")	
		get_tree().change_scene_to_file("res://Cenas/Menu.tscn")


func _on_bt_curar_pressed() -> void:
	vida = 3
	vidas.atualizar_vida(vida)
