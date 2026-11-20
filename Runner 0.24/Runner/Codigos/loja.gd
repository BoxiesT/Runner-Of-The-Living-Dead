extends Control

signal item_comprado(tipo:String, valor:Variant)

@onready var slot_1: Control = $Posições/Slot1
@onready var slot_2: Control = $Posições/Slot2
@onready var slot_3: Control = $Posições/Slot3

@onready var label_1: Label = $Posições/Slot1/Label
@onready var label_2: Label = $Posições/Slot2/Label
@onready var label_3: Label = $Posições/Slot3/Label

@onready var player: CharacterBody2D = $"../Run/Player"
@onready var moscas_label: Label = $"../Hud/Moscas"


@export var itens_disponiveis: Array[PackedScene]

#Iniciar a loja, vindo da main
func iniciar_loja():
	#print("funciona")
	gerar_loja()

#Cria a loja
func gerar_loja() -> void:
	limpar_loja()
	var posicoes = [
		slot_1,
		slot_2,
		slot_3,
	]
	
	var precos = [
		label_1,
		label_2,
		label_3,
	]
	
	for i in range(posicoes.size()):
		var cena = sortear_item()
		if cena == null:
			return
		
		var item = cena.instantiate()
		
		#conecta o sinal quando gerado
		item.comprado.connect(_on_item_base_comprado)
		
		add_child(item)
		item.position = posicoes[i].position
		
		precos[i].text = str(item.preco)

func sortear_item() -> PackedScene:
	if itens_disponiveis.is_empty():
		return null
	var indice = randi_range(0,itens_disponiveis.size() -1)
	return itens_disponiveis[indice]

func limpar_loja() -> void:
	for filho in get_children():
		if filho is ItemBase:
			filho.queue_free()


#Informar main dos itens comprados
func _on_item_base_comprado(tipo: String, valor: Variant, preco, item:ItemBase) -> void:
	if player.moscas < preco:
		#quando não tem dinheiro
		return
	player.gastar_moscas(preco)
	item.desativar_item()
	print("comprou ", tipo + " ", str(valor) + " ", str(preco))
	item_comprado.emit(tipo,valor)

#atualiza a widget das moscas
func atualizar_moscas():
	moscas_label.text = str(player.moscas)
