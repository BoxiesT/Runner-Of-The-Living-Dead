extends Node

@onready var score_label: Label = $CanvasLayer/Score_Label


const score_per_second: float = 100.0

var score: float = 0.0
var multiplier: float = 1.0


func start_score(d):
	score += score_per_second * multiplier * d
	
func add_score(amount: float):
	score += amount * multiplier

func multiply_score(value: float):
	score *= value

func add_multiplier(value: float):
	multiplier += value

func set_multiplier(value: float):
	multiplier = value

func reset_score():
	score = 0.0
	multiplier = 1.0

func get_score() -> int:
	return int(score)

func set_score(value: float):
	score = value
	
func atualizar_label():
	score_label.text = "Score: " + str(get_score()) + " | " + str(multiplier) + "X"
