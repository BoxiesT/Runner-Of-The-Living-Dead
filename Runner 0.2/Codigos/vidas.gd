extends Control


@onready var coracoes = [
	$coracoes1, $coracoes2, $coracoes3
]

var vida_maxima := 3
var vida_atual := 3

func atualizar_vida(nova_vida: int) -> void:
	vida_atual = clamp(nova_vida, 0, vida_maxima)

	for i in range(coracoes.size()):
		if i < vida_atual:
			coracoes[i].modulate.a = 1.0
		else:
			coracoes[i].modulate.a = 0.3
