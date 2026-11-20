class_name ItemBase
extends Button

signal comprado(tipo: String, valor: Variant, preco:int)

@export var nome_item: String = "Item"
@export var preco: int = 0

func desativar_item():
	disabled = true
