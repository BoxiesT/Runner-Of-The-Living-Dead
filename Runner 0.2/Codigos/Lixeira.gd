extends Area2D

@export var velocidade: float = 300.0

func _ready() -> void:
	add_to_group("obstaculos")
#move para esquerda 
func  _process (delta: float) -> void:
	position.x -= velocidade * delta

#uando algo entra na colisão
func _on_body_entered(body: Node2D) -> void:
	if body.has_method("tomar_dano"):
		body.tomar_dano()
		if position.x > -20:
			queue_free()
			
	elif body.has_method("morrer"):
		body.morrer()
		queue_free()
	
