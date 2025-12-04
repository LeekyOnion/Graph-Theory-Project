extends Node3D
class_name BoardManager

## Variables
@export_subgroup("Scene")
@export var node_object : PackedScene;
@export var main_camera : Camera3D;

@export_subgroup("Board Dimensions")
@export_range(1,100,1) var board_height: int = 5;
@export_range(1,100,1) var board_width : int = 5;
@export_range(0, 1.0, 0.1) var board_gap : float = 0.1;

@export_subgroup("PlaneMesh height and width")
@export_range(1,10,1) var mesh_height: int = 2;
@export_range(1,10,1) var mesh_width : int = 2;

@export_subgroup("Pathing Requirements")
@export_range(1, 100, 1) var number_of_checkpoints : int = 3;
@export_range(0, 1, 0.1) var tree_area_coverage : float = 0.50;

@export_subgroup("Buildings and Roads")
@export var start_building : PackedScene;
@export var end_building : PackedScene;
@export var checkpoint_building : PackedScene;
@export var road : PackedScene;
@export var tree_1 : PackedScene;
@export var tree_2 : PackedScene;

var path_colors : Array[Color] = [
	Color.hex(0x999999FF), Color.hex(0x666666FF),
	Color.hex(0x333333FF), Color.hex(0x1a1a1aFF)
]

## Tile Map
var tile_map : Dictionary = {};
var start_coordinates : Vector2i;
var end_coordinates   : Vector2i;
var checkpoint_coordinates : Array[Vector2i] = [];

var building_instances : Dictionary = {};

## Adjaceny
const cardinal_directions : Array[Vector2i] = [
	Vector2i(0,1), # North
	Vector2i(0,-1), # South
	Vector2i(1,0), # East
	Vector2i(-1,0) # West
]

func _ready() -> void:
	if node_object and start_building and end_building and road:
		generate_board();
	else:
		print("Error: Required PackedScenes (Tile, Start/End Building, Road) have not been set in the Inspector.");

func generate_board() -> void:
	
	var effective_width : float = mesh_width + board_gap;
	var effective_height: float = mesh_height + board_gap;
	
	var total_width  : float = board_width * effective_width;
	var total_height : float = board_height * effective_height;
	
	var start_x : float = (-total_width / 2.0) + (mesh_width / 2.0);
	var start_z : float = (-total_height / 2.0) + (mesh_height /2.0);
	
	## Build the board (Tiles)
	for x in range(board_width):
		for z in range(board_height):
			
			var object_instance : MeshInstance3D = node_object.instantiate();
			var current_coordinates = Vector2i(x, z);
			
			var pos_x : float = start_x + x * effective_width;
			var pos_z : float = start_z + z * effective_height;
			
			object_instance.position = Vector3(pos_x, 0, pos_z);
			object_instance.name = "tile_%d_%d" % [x,z];
			
			add_child(object_instance)
			tile_map[current_coordinates] = object_instance;
			
	choose_start_end_nodes();
	generate_checkpoints();
	
	var full_path = get_full_required_path();
	_place_path_elements(full_path);
	_place_trees();
	
	if main_camera:
		_adjust_camera(total_width, total_height);

## BOARD NODE SELECTION AND PLACEMENT ##
func get_tile_position(coord: Vector2i) -> Vector3:
	var tile = tile_map.get(coord) as MeshInstance3D;
	return tile.position if tile else Vector3.ZERO;

func place_node_instance(coord: Vector2i, packed_scene: PackedScene) -> void:
	if not packed_scene: return;
	var instance = packed_scene.instantiate();
	var tile_pos = get_tile_position(coord);
	
	instance.position = tile_pos + Vector3(0, 0.1, 0);
	add_child(instance);
	
	building_instances[coord] = instance;

## BFS ALGORITHM
## 1. Choose Start and End Locations
func choose_start_end_nodes() -> void:
	
	var corner_coordinates : Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(board_width - 1, 0),
		Vector2i(0, board_height - 1), Vector2i(board_width - 1, board_height - 1)
	];
	
	var edge_coordinates : Array[Vector2i] = [];
	for x in range(board_width):
		for z in range(board_height):
			var coord = Vector2i(x, z);
			var is_on_edge: bool = (x == 0 or x == (board_width - 1) or \
									z == 0 or z == (board_height - 1));
			var is_not_corner: bool = not corner_coordinates.has(coord);
			if is_on_edge and is_not_corner:
				edge_coordinates.append(coord);
				
	if edge_coordinates.size() < 2:
		print("Not possible to select 2 non-corner edge nodes (Board too small?).")
		return;

	## SHUFFLE AND SELECT START COORDINATE
	edge_coordinates.shuffle();
	var local_start_coordinates : Vector2i = edge_coordinates[0];
	var start_quadrant = get_quadrant(local_start_coordinates);
	
	## FILTER REMAINING COORDINATES FOR END NODE SELECTION (Same criteria)
	var valid_end_coordinates : Array[Vector2i] = [];
	for coord in edge_coordinates:
		if coord == local_start_coordinates: continue;
		if coord.x == local_start_coordinates.x or coord.y == local_start_coordinates.y: continue;
		if get_quadrant(coord) != start_quadrant:
			valid_end_coordinates.append(coord);
			
	if valid_end_coordinates.size() == 0:
		print("Could not find a valid end coordinate that meets all criteria.")
		return;

	## SELECT END COORDINATE
	valid_end_coordinates.shuffle();
	var local_end_coordinates : Vector2i = valid_end_coordinates[0];
	
	## ASSIGN COORDINATES AND PLACE BUILDINGS (NEW)
	start_coordinates = local_start_coordinates;
	end_coordinates = local_end_coordinates;
	
	place_node_instance(start_coordinates, start_building);
	place_node_instance(end_coordinates, end_building);

## 2. Generate Checkpoints
func generate_checkpoints() -> void:
	var all_coordinates : Array = tile_map.keys();
	var interior_coordinates : Array[Vector2i] = [];
	
	## Identify Interior Tiles
	for x in range(1, board_width - 1):
		for z in range(1, board_height - 1):
			interior_coordinates.append(Vector2i(x, z));
	
	## Filter out the Start/Ending Quadrants
	var used_quadrants: Array[int] = [get_quadrant(start_coordinates), get_quadrant(end_coordinates)];
	
	## Determine Other Quadrants (for preferred placement)
	var target_quadrants: Array[int] = [];
	for q in range(1, 5):
		if not used_quadrants.has(q):
			target_quadrants.append(q);
			
	var available_coordinates : Array[Vector2i] = [];
	var fallback_coordinates : Array[Vector2i] = []; # NEW: For non-quadrant tiles
	for coord in interior_coordinates:
		if coord == start_coordinates or coord == end_coordinates:
			continue;
		
		# Must be in one of the target quadrants (Preferred)
		if target_quadrants.has(get_quadrant(coord)):
			available_coordinates.append(coord);
		else:
			# NEW: Coordinates that are NOT in target quadrants
			fallback_coordinates.append(coord);
	
	# Combine and shuffle all interior non-start/end tiles
	var all_interior_coords = available_coordinates + fallback_coordinates;
	all_interior_coords.shuffle();
	
	if all_interior_coords.size() < number_of_checkpoints:
		print("Error: Not enough available interior tiles for %d checkpoints. Try a larger board." % number_of_checkpoints);
		return;
		
	## INITIAL STRICT CHECKPOINT SELECTION
	var strict_candidates : Array[Vector2i] = all_interior_coords.duplicate();
	
	var used_x_coords : Array[int] = [];
	var used_z_coords : Array[int] = [];
	
	used_x_coords.append(start_coordinates.x);
	used_z_coords.append(start_coordinates.y);
	used_x_coords.append(end_coordinates.x);
	used_z_coords.append(end_coordinates.y);
	
	var checkpoint_count : int = 0;
	var current_index    : int = 0;
	
	var remaining_candidates : Array[Vector2i] = [];
	
	## Hard Placement Logic
	while checkpoint_count < number_of_checkpoints and current_index < strict_candidates.size():
		var candidate_checkpoint = strict_candidates[current_index];
		var x = candidate_checkpoint.x;
		var z = candidate_checkpoint.y;
		var is_valid = true;
		
		if used_x_coords.has(x) or used_z_coords.has(z):
			is_valid = false;
				
		if is_valid:
			checkpoint_coordinates.append(candidate_checkpoint);
			used_x_coords.append(x);
			used_z_coords.append(z);
				
			checkpoint_count += 1;
			place_node_instance(candidate_checkpoint, checkpoint_building);
		else:
			remaining_candidates.append(candidate_checkpoint);
				
		current_index += 1;

	## After Hard Placement Logic
	## Fill in with looser rules
	if checkpoint_count < number_of_checkpoints:
		remaining_candidates.shuffle(); 
		
		for candidate in remaining_candidates:
			if checkpoint_count >= number_of_checkpoints: break;
			
			if not checkpoint_coordinates.has(candidate):
				
				if candidate != start_coordinates and candidate != end_coordinates:
					checkpoint_coordinates.append(candidate);
					checkpoint_count += 1;
					place_node_instance(candidate, checkpoint_building);

	if checkpoint_count < number_of_checkpoints:
		print("Warning: Only found %d/%d total checkpoints that satisfied base constraints (not S/E or previous CP). Try a larger board size." % [checkpoint_count, number_of_checkpoints]);
		
	elif checkpoint_coordinates.size() < number_of_checkpoints:
		print("Warning: %d strict checkpoints and %d fallback checkpoints placed." % [current_index - remaining_candidates.size(), number_of_checkpoints - (current_index - remaining_candidates.size())]);

## 3. BFS Algorithm to Find path between Start/End/Checkpoint
func find_path(start: Vector2i, end: Vector2i) -> Array[Vector2i]:
	## [Coordinate, Distance]
	var queue : Array = [[start]];
	var come_from : Dictionary = {start : null};
	var visited : Dictionary = {};
	visited[start] = true;
	
	while queue.size() > 0:
		var current_item = queue.pop_front();
		var current_coordinate : Vector2i = current_item[0];
		
		if current_coordinate == end:
			return _reconstruct_path(come_from, end);
				
		for direction in cardinal_directions:
			var neighbor_coordinate : Vector2i = current_coordinate + direction;
			
			if not is_valid_coordinate(neighbor_coordinate): continue;
			if visited.has(neighbor_coordinate): continue;
				
			visited[neighbor_coordinate] = true;
			come_from[neighbor_coordinate] = current_coordinate;
			queue.append([neighbor_coordinate]);
			
	return []

## 4. Reconstruct the Path
func _reconstruct_path(come_from : Dictionary, current_coordinate : Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = [];
	var temp_coordinate = current_coordinate;
	
	while temp_coordinate != null:
		path.append(temp_coordinate);
		temp_coordinate = come_from.get(temp_coordinate);
	
	path.reverse();
	return path;

func is_valid_coordinate(coordinate : Vector2i) -> bool:
	return tile_map.has(coordinate);

## Road/Tree Placement Logic ##
## Due to the how I originally coded this, rebuilds a path. _place_path_elements is completely
## reliant on this function therefore it remains. It used to color code the paths.

func get_full_required_path() -> Array:
	
	var required_nodes : Array[Vector2i] = [];
	required_nodes.append(start_coordinates);
	
	for checkpoint in checkpoint_coordinates:
		required_nodes.append(checkpoint);
	required_nodes.append(end_coordinates);

	var colored_segments : Array = [];
	
	for i in range(required_nodes.size() - 1):
		var start_node : Vector2i = required_nodes[i];
		var end_node : Vector2i= required_nodes[i + 1];
		
		var color_index : int = i % path_colors.size();
		var segment_color : Color = path_colors[color_index];
	
		var segment_path : Array[Vector2i] = find_path(start_node, end_node);
		
		if segment_path.is_empty():
			print("Error: Could not find path from %s to %s" % [start_node, end_node]);
			return [];
			
		var path_to_add: Array[Vector2i];
		
		if i == 0:
			path_to_add = segment_path;
		else:
			## Excludes start node
			path_to_add = segment_path.slice(1, segment_path.size());
			
		colored_segments.append({
			"path": path_to_add,
			"color": segment_color
		});
		
	return colored_segments;

func _place_path_elements(colored_segments: Array) -> void:
	if colored_segments.is_empty() or not road:
		return;
		
	## Rotation constants for the road mesh
	const X_ROTATION = Vector3(0, deg_to_rad(90), 0);
	const Z_ROTATION = Vector3.ZERO;
	
	var building_connectors : Dictionary = {};

	for segment in colored_segments:
		var path_segment : Array[Vector2i] = segment.path;
		#var color : Color = segment.color;
		
		for i in range(path_segment.size() - 1):
			var current_coord = path_segment[i];
			var next_coord = path_segment[i+1];
			
			var current_pos = get_tile_position(current_coord);
			var next_pos = get_tile_position(next_coord);
			
			var direction_vector = next_coord - current_coord;
			var road_rotation = Z_ROTATION;
			if direction_vector.x != 0:
				road_rotation = X_ROTATION;
			
			var span_instance = road.instantiate();
			span_instance.position = (current_pos + next_pos) / 2.0;
			span_instance.position.y = 0.1;
			span_instance.rotation = road_rotation;
			add_child(span_instance);

			if current_coord == start_coordinates or checkpoint_coordinates.has(current_coord):
				building_connectors[current_coord] = direction_vector; 
				
			if next_coord == end_coordinates:
				building_connectors[next_coord] = direction_vector; 
	
	for coord in building_connectors.keys():
		var direction_vector = building_connectors[coord] as Vector2i;

		var building_yaw_angle: float = get_yaw_angle_from_direction(direction_vector);

		if building_instances.has(coord):
			var building = building_instances[coord] as Node3D;
			building.rotation.y = building_yaw_angle;

func _place_trees() -> void:
	var used_tiles : Dictionary = _get_used_tiles();
	
	var available_tiles : Array[Vector2i] = [];
	
	for coord in tile_map.keys():
		if not used_tiles.has(coord):
			available_tiles.append(coord);
			
	if available_tiles.is_empty():
		return;
		
	var num_available_tiles = available_tiles.size();
	var num_trees_to_place = int(floor(num_available_tiles * tree_area_coverage));
	
	if num_trees_to_place <= 0:
		return;
		
	available_tiles.shuffle();
	
	var tree_scenes = [tree_1, tree_2].filter(func(t): return t != null);
	if tree_scenes.is_empty():
		print("Warning: No tree PackedScenes (tree_1 or tree_2) are assigned.");
		return;
		
	for i in range(min(num_trees_to_place, available_tiles.size())):
		var coord = available_tiles[i];
		var tile_pos = get_tile_position(coord);
		
		var tree_scene = tree_scenes[randi() % tree_scenes.size()];
		
		var tree_instance = tree_scene.instantiate();
		
		tree_instance.position = tile_pos + Vector3(0, 0.1, 0);
		add_child(tree_instance);

## Support Functions ##

func get_yaw_angle_from_direction(direction: Vector2i) -> float:
	if direction == Vector2i(0, 1):
		return 0.0;
	elif direction == Vector2i(0, -1):
		return deg_to_rad(180.0);
	elif direction == Vector2i(1, 0):
		return deg_to_rad(90.0);
	elif direction == Vector2i(-1, 0):
		return deg_to_rad(-90.0);
	return 0.0;

func get_quadrant(coord: Vector2i) -> int:
	var x_center : int = board_width / 2;
	var z_center : int = board_height / 2;
	
	var is_right : bool = coord.x >= x_center;
	var is_top   : bool = coord.y >= z_center;
	
	if is_top:
		if is_right:
			return 2;
		else:
			return 1;
	else:
		if is_right:
			return 4;
		else:
			return 3;

func _get_used_tiles() -> Dictionary:
	var used_tiles : Dictionary = {};
	
	var building_coords : Array[Vector2i] = [];
	building_coords.append(start_coordinates);
	building_coords.append(end_coordinates);
	for coord in checkpoint_coordinates:
		building_coords.append(coord);

	for coord in building_coords:
		used_tiles[coord] = true;
		
		for direction in cardinal_directions:
			var neighbor_coord = coord + direction;

			if is_valid_coordinate(neighbor_coord):
				used_tiles[neighbor_coord] = true;

	# 2. Add all tiles covered by roads
	var full_path_segments = get_full_required_path();
	
	for segment in full_path_segments:
		var path_segment: Array[Vector2i] = segment.path;
		for coord in path_segment:
			# Roads also prevent tree placement
			used_tiles[coord] = true;
			
	return used_tiles;

func _adjust_camera(board_visual_width: float, board_visual_height: float) -> void:
	
	var max_dimensions = max(board_visual_width, board_visual_height);
	
	var camera_distance_multiplier: float = 1.0; 
	var distance_needed = max_dimensions * camera_distance_multiplier;
	
	var center_point = Vector3(0, 0, 0);
	
	var new_pos = Vector3(
		0, 
		distance_needed * 0.6, 
		distance_needed * -0.6
	);
	
	main_camera.global_transform.origin = new_pos;
	main_camera.look_at(center_point, Vector3.UP);
	
func cleanup_board() -> void:
	for child in get_children().duplicate():
		child.queue_free();
	
	tile_map.clear();
	
	checkpoint_coordinates.clear();
	start_coordinates = Vector2i.ZERO;
	end_coordinates = Vector2i.ZERO;
