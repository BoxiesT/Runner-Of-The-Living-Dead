extends CanvasLayer

@onready var mult_label: Label = $Mult_Label

const multiplicador_base: float = 1.0

var tween_mult: Tween
var multiplicador_atual: float = 0.0


func animar_multiplicador(valor:float) -> void:
	multiplicador_atual = valor
	mult_label.text = str(valor) + "X"
	
	if tween_mult and tween_mult.is_running():
		tween_mult.kill()
	
	mult_label.scale = Vector2.ONE
	
	tween_mult = create_tween()
	
	tween_mult.tween_property(
		mult_label,
		"scale",
		Vector2(1.5,1.5),
		0.12
	). set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		
	tween_mult.tween_property(
		mult_label,
		"scale",
		Vector2.ONE,
		0.2
	).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	

func resetar_multiplicador()-> void:
	print(multiplicador_atual)
	if multiplicador_atual <= multiplicador_base:
		return
	animar_multiplicador(multiplicador_base)
