extends ItemBase

var multiplicador: float = 2.0

func _ready() -> void:
	pressed.connect(comprar)
	
func comprar() -> void:
	comprado.emit("Score_2x", multiplicador, preco, self)
	
