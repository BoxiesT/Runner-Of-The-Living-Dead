extends CharacterBody2D


const SPEED = 300.0
const JUMP_VELOCITY = -400.0

const JUMP_BUFFER: float = 0.15
var jump_buffer: float = 0.0

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
