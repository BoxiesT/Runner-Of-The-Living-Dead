extends ItemBase

var multiplicador: float = 4.0


func _ready() -> void:
	pressed.connect(comprar)

func comprar() -> void:
	comprado.emit("Score_4x", multiplicador, preco, self)
	
