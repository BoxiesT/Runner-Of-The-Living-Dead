extends Control

func _on_button_jogar_pressed() -> void:
	get_tree().change_scene_to_file("res://Cenas/Main.tscn")


func _on_button_sair_pressed() -> void:
	get_tree().quit()
	

func _on_button_creditos_pressed() -> void:
	get_tree().change_scene_to_file("res://Cenas/credittos.tscn")	
