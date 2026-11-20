extends Area2D

@export var velocidade: float = 550.0 

func _ready() -> void:
	add_to_group("obstaculos")
	
func _process(delta: float) -> void:
	position.x -= velocidade * delta 
	
func _on_body_entered(body: Node2D) -> void:
	if body.has_method("tomar_dano"):
		body.tomar_dano()
		if position.x > -20:
			queue_free()
	
	
