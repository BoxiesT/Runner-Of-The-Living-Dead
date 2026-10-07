extends Node

signal run_finished

const distance_per_second: float = 10.0

var distance := 0.0
var target_distance := 50
var run_ended := false

func start_run(distance_goal: float) -> void:
	distance = 0.0
	target_distance = distance_goal
	run_ended = false

func add_distance(d):
	if run_ended:
		return
	distance += distance_per_second * d
	print(distance)
	if distance >= target_distance:
		finish_run()

func finish_run():
	if run_ended:
		return
	run_ended = true
	run_finished.emit()
