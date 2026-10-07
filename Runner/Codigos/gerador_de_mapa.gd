class_name MapGenerator
extends Node

const X_DIST := 50 # gap entre colunas
const Y_DIST := 40 # gap entre linhas

const PLACEMENT_RANDOMNESS := 5 # margem de variação nas distancias

const MAP_WIDTH := 4  # numero de colunas
const FLOORS := 10  # numero de linhas 

const PATHS : = 4 # quantidade de caminhos

#chance de spawn de cada sala
const RUN_ZONE_WEIGHT := 10.0 
const SHOP_ZONE_WEIGHT := 2.5
const HEALTH_ZONE_WEIGHT := 4.0

var random_zone_type_weights = {
	Room.Type.RUN: 0.0,
	Room.Type.HEALTH: 0.0,
	Room.Type.SHOP: 0.0,
}
var random_zone_type_total_weight := 0

var map_data: Array[Array]

func generate_map() -> Array[Array]:
	map_data = _generate_initial_grid()
	var starting_points := _get_ramdom_starting_points()
	
	for j in starting_points:
		var current_j := j
		for i in FLOORS - 1: # -1 considera a sala do boss
			current_j = _setup_conection(i, current_j)
	
	_setup_boss_zone()
	_setup_ramdom_zone_weights()
	_setup_zope_types()
	
	
	return map_data

func _generate_initial_grid() -> Array[Array]:
	var result: Array[Array] = []
	for i in FLOORS:
		var adjacent_rooms: Array[Room] = []
		
		for j in MAP_WIDTH:
			var current_room := Room.new()
			var offset := Vector2(randf(), randf()) * PLACEMENT_RANDOMNESS
			current_room.position = Vector2(j * X_DIST, i * -Y_DIST) + offset
			current_room. row = i
			current_room.column = j
			current_room.next_rooms = []
			
			#Boss room
			if i == FLOORS - 1:
				current_room.position.y = (i + 1) * -Y_DIST
			
			adjacent_rooms.append(current_room)
		result.append(adjacent_rooms)
	return result

func _get_ramdom_starting_points() -> Array[int]:
	var y_coordinates: Array[int]
	var unique_points: int = 0
	
	while unique_points < 2:
		unique_points = 0
		y_coordinates = []
		
		for i in PATHS:
			var starting_point := randi_range(0, MAP_WIDTH  - 1)
			if not y_coordinates.has(starting_point):
				unique_points += 1
				
			y_coordinates.append(starting_point)
	return y_coordinates

func _setup_conection(i: int, j: int) -> int:
	var next_room: Room
	var current_room := map_data[i][j] as Room
	
	while not next_room or _would_cross_existing_path(i,j,next_room):
		var random_j := clampi(randi_range(j - 1, j + 1), 0, MAP_WIDTH - 1)
		next_room = map_data[i + 1][random_j]
	
	current_room.next_rooms.append(next_room)
	return next_room.column

func _would_cross_existing_path(i:int, j: int, room:Room) -> bool:
	var left_neighbour: Room
	var right_neighbour: Room
	
	if j > 0:
		left_neighbour = map_data[i][j - 1]
	if j < MAP_WIDTH - 1:
		right_neighbour = map_data[i][j + 1]
	
	if right_neighbour and room.column > j :
		for next_room: Room in right_neighbour.next_rooms:
			if next_room.column < room.column:
				return true
	
	if left_neighbour and room.column < j:
		for next_room: Room in left_neighbour.next_rooms:
			if next_room.column > room.column:
				return true
	return false

func _setup_boss_zone() -> void:
	var middle := floori(MAP_WIDTH * 0.5)
	var boss_room := map_data[FLOORS - 1][middle] as Room
	
	for j in MAP_WIDTH:
		var curretent_room = map_data[FLOORS - 2][j] as Room
		if curretent_room.next_rooms:
			curretent_room.next_rooms = [] as Array[Room]
			curretent_room.next_rooms.append(boss_room)
	
	boss_room.type = Room.Type.BOSS

func _setup_ramdom_zone_weights() -> void:
	random_zone_type_weights[Room.Type.RUN] = RUN_ZONE_WEIGHT
	random_zone_type_weights[Room.Type.HEALTH] = RUN_ZONE_WEIGHT + HEALTH_ZONE_WEIGHT
	random_zone_type_weights[Room.Type.SHOP] = RUN_ZONE_WEIGHT + HEALTH_ZONE_WEIGHT + SHOP_ZONE_WEIGHT
	
	random_zone_type_total_weight = random_zone_type_weights[Room.Type.SHOP]

func _setup_zope_types() -> void:
	for room: Room in map_data[0]:
		if room.next_rooms.size() > 0:
			room.type = Room.Type.RUN
			
	for current_floor in map_data:
		for room: Room in current_floor:
			for next_room: Room in room.next_rooms:
				if next_room.type == Room.Type.NOT_ASSINED:
					_set_zone_randomly(next_room)
	
func _set_zone_randomly(room_to_set:Room) -> void:
	var consecutive_health := true
	var consecutive_shop := true
	
	var type_candidate: Room.Type
	
	while consecutive_health or consecutive_shop:
		type_candidate = _get_random_zone_type_by_weight()
		
		var is_health := type_candidate == Room.Type.HEALTH
		var has_health_parent := _zone_has_parent_of_type(room_to_set, Room.Type.HEALTH)
		var is_shop := type_candidate == Room.Type.SHOP
		var has_shop_parent := _zone_has_parent_of_type(room_to_set, Room.Type.SHOP)

		consecutive_health = is_health and has_health_parent
		consecutive_shop = is_shop and has_shop_parent
	room_to_set.type = type_candidate
	
func  _zone_has_parent_of_type(room:Room, type: Room.Type) -> bool:
	var parents: Array[Room] = []
	#left
	if room.column > 0 and room.row > 0:
		var parent_candidate := map_data[room.row - 1][room.column - 1] as Room
		if parent_candidate.next_rooms.has(room):
			parents.append(parent_candidate)
	#below
	if room.row > 0:
		var parent_candidate := map_data[room.row - 1][room.column] as Room
		if parent_candidate.next_rooms.has(room):
			parents.append(parent_candidate)
	#right
	if room.column < MAP_WIDTH-1 and room.row > 0:
		var parent_candidate := map_data[room.row - 1][room.column + 1] as Room
		if parent_candidate.next_rooms.has(room):
				parents.append(parent_candidate)
				
	for parent: Room in parents:
		if parent.type == type:
			return true
	
	return false

func _get_random_zone_type_by_weight() -> Room.Type:
	var roll := randf_range(0.0, random_zone_type_total_weight)
	
	for type: Room.Type in random_zone_type_weights:
		if random_zone_type_weights[type] > roll:
			return type
	
	return Room.Type.RUN
	
