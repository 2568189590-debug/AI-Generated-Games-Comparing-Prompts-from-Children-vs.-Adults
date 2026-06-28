@tool
extends Node3D

var clipmap_tile_size := 1.0
var previous_tile := Vector3i.MAX
var should_render_imgui := false  # Start hidden to avoid ImGui intercepting input
var _default_cache : Dictionary = {}
var _imgui_debug_ui: RefCounted = null  # Loaded dynamically; nil when ImGui GDExtension unavailable

# Game mode nodes (created programmatically)
var _game_manager: GameManager = null
var _drone: DroneController = null
var _drone_camera: DroneCamera = null
var _game_ui: GameUI = null
var _obstacle_spawner: ObstacleSpawner = null
var _person: Person = null

@onready var viewport : Variant = get_viewport()
@onready var camera : Camera3D = $Camera
@onready var water := $Water

@onready var _camera_fov : Array[float] = [camera.fov]
@onready var _updates_per_second : Array[float] = [water.updates_per_second]
@onready var _water_color : Array[float] = [water.water_color.r, water.water_color.g, water.water_color.b]
@onready var _foam_color : Array[float] = [water.foam_color.r, water.foam_color.g, water.foam_color.b]
@onready var _is_sea_spray_visible : Array[bool] = [true]
@onready var _update_textures : Array[bool] = [true]

@onready var _crest_color : Array[float] = [0.0, 0.65, 0.85]
@onready var _crest_glow_intensity : Array[float] = [0.8]
@onready var _aerated_foam_glow : Array[float] = [0.5]

func _ready() -> void:
	if Engine.is_editor_hint(): return

	# DEBUG: Red box to confirm _ready() runs
	var debug_red := MeshInstance3D.new()
	debug_red.name = "DEBUG_RED"
	debug_red.mesh = BoxMesh.new()
	debug_red.position = Vector3(0, 5, 0)
	debug_red.scale = Vector3(2, 2, 2)
	var red_mat := StandardMaterial3D.new()
	red_mat.albedo_color = Color.RED
	debug_red.material_override = red_mat
	add_child(debug_red)

	# Window setup
	if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	var screen_size := Vector2(DisplayServer.screen_get_size())
	DisplayServer.window_set_size(Vector2i(screen_size * 0.75))
	DisplayServer.window_set_position(Vector2i(screen_size * 0.25 / 2.0))

	_default_cache["fov"] = camera.fov
	_default_cache["map_size"] = water.map_size
	_default_cache["mesh_quality"] = water.mesh_quality
	_default_cache["clipmap_tile"] = clipmap_tile_size
	_default_cache["updates"] = water.updates_per_second
	_default_cache["water_color"] = water.water_color
	_default_cache["foam_color"] = water.foam_color
	_default_cache["sea_spray"] = $Water/WaterSprayEmitter.visible
	_default_cache["update_tex"] = water.update_textures

	_default_cache["crest_color"] = Color(_crest_color[0], _crest_color[1], _crest_color[2])
	_default_cache["crest_glow"] = _crest_glow_intensity[0]
	_default_cache["aerated_glow"] = _aerated_foam_glow[0]

	var default_cascades : Array[WaveCascadeParameters] = []
	for p in water.parameters:
		default_cascades.append(p.duplicate(true))
	_default_cache["cascades"] = default_cascades

	# DEBUG: Blue box before game setup
	var debug_blue := MeshInstance3D.new()
	debug_blue.name = "DEBUG_BLUE"
	debug_blue.mesh = BoxMesh.new()
	debug_blue.position = Vector3(5, 5, 0)
	debug_blue.scale = Vector3(2, 2, 2)
	var blue_mat := StandardMaterial3D.new()
	blue_mat.albedo_color = Color.BLUE
	debug_blue.material_override = blue_mat
	add_child(debug_blue)

	_try_load_imgui_debug_ui()
	_setup_game_mode()

	# DEBUG: Green box to confirm _setup_game_mode() completed
	var debug_green := MeshInstance3D.new()
	debug_green.name = "DEBUG_GREEN"
	debug_green.mesh = BoxMesh.new()
	debug_green.position = Vector3(10, 5, 0)
	debug_green.scale = Vector3(2, 2, 2)
	var green_mat := StandardMaterial3D.new()
	green_mat.albedo_color = Color.GREEN
	debug_green.material_override = green_mat
	add_child(debug_green)

func _process(_delta : float) -> void:
	if not Engine.is_editor_hint():
		if should_render_imgui and _imgui_debug_ui:
			_imgui_debug_ui.render()
			camera.enable_camera_movement = not _imgui_debug_ui.is_imgui_hovered()

func _physics_process(_delta: float) -> void:
	# Water mesh recentering — only applies to the free camera, not the drone
	if not _game_manager or _game_manager.get_state() == GameManager.GameState.PLAYING:
		pass # Don't recenter in game mode; the drone moves freely
	else:
		# Original recentering logic when game is over or not active
		var tile := (Vector3(camera.global_position.x, 0.0, camera.global_position.z) / clipmap_tile_size).ceil()
		if not tile.is_equal_approx(previous_tile):
			water.global_position = tile * clipmap_tile_size
			previous_tile = tile

	# Audio crossfade based on wind speed
	var total_wind_speed := 0.0
	for params in water.parameters:
		total_wind_speed += params.wind_speed
	$OceanAudioPlayer.volume_db = lerpf(-30.0, 15.0, minf(total_wind_speed/15.0, 1.0))
	$WindAudioPlayer.volume_db = lerpf(5.0, -30.0, minf(total_wind_speed/15.0, 1.0))

func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&'toggle_imgui'):
		should_render_imgui = not should_render_imgui
	elif event.is_action_pressed(&'toggle_fullscreen'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED else DisplayServer.WINDOW_MODE_WINDOWED)
	elif event.is_action_pressed(&'ui_cancel'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

# ============================================================
#  Game Mode Setup
# ============================================================

func _setup_game_mode() -> void:
	# 1. Create all nodes first (before adding to tree)
	_game_manager = GameManager.new()
	_game_manager.name = "GameManager"

	_drone = _create_drone_node()
	_drone.water = water

	_obstacle_spawner = ObstacleSpawner.new()
	_obstacle_spawner.name = "ObstacleSpawner"
	_obstacle_spawner.water = water
	_obstacle_spawner.drone = _drone

	_game_ui = GameUI.new()
	_game_ui.name = "GameUI"

	_person = _create_person_node()
	_person.water = water

	# 2. Wire all references BEFORE any _ready() fires
	_game_manager.water = water
	_game_manager.drone = _drone
	_game_manager.drone_camera = _drone_camera
	_game_manager.obstacle_spawner = _obstacle_spawner
	_game_manager.game_ui = _game_ui
	_game_manager.free_camera = camera
	_game_manager.person = _person

	_game_ui.drone = _drone
	_game_ui.drone_camera = _drone_camera

	# 3. Now add all nodes to the tree (GameManager last so its _ready()
	#    fires after all other nodes are ready)
	add_child(_drone)
	add_child(_obstacle_spawner)
	add_child(_person)
	add_child(_game_ui)
	add_child(_game_manager)

func _create_person_node() -> Person:
	var person := Person.new()
	person.name = "Person"
	# Place at a random position ~150m in front of the drone spawn point
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var angle := rng.randf_range(0.0, TAU)
	var distance := rng.randf_range(80.0, 200.0)
	person.position = Vector3(
		cos(angle) * distance,
		0.0,  # Y set by wave height in _physics_process
		sin(angle) * distance - 20.0  # offset from drone spawn z=-20
	)
	return person

func _create_drone_node() -> DroneController:
	var drone := DroneController.new()
	drone.name = "Drone"
	drone.position = Vector3(0.0, 15.0, -20.0)
	drone.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	drone.up_direction = Vector3.UP
	drone.collision_layer = 1  # drone is on layer 1
	drone.collision_mask = 1 | (1 << (Obstacle.COLLISION_LAYER_OBSTACLE - 1)) | (1 << (Person.COLLISION_LAYER_PERSON - 1))

	# Collision shape for CharacterBody
	var body_col := CollisionShape3D.new()
	body_col.name = "CollisionShape3D"
	var body_shape := CylinderShape3D.new()
	body_shape.radius = 0.7
	body_shape.height = 1.0
	body_col.shape = body_shape
	drone.add_child(body_col)

	# HitBox Area3D (overlap detection for obstacles)
	var hit_box := Area3D.new()
	hit_box.name = "HitBox"
	hit_box.collision_layer = 0
	hit_box.collision_mask = (1 << (Obstacle.COLLISION_LAYER_OBSTACLE - 1)) | (1 << (Person.COLLISION_LAYER_PERSON - 1))
	var hb_shape_node := CollisionShape3D.new()
	hb_shape_node.name = "CollisionShape3D"
	var hb_sphere := SphereShape3D.new()
	hb_sphere.radius = 3.0
	hb_shape_node.shape = hb_sphere
	hit_box.add_child(hb_shape_node)
	drone.add_child(hit_box)

	# DroneModel (visual root — populated by DroneController._build_drone_model)
	var model_root := Node3D.new()
	model_root.name = "DroneModel"
	drone.add_child(model_root)

	# SpringArm3D + DroneCamera
	var spring_arm := SpringArm3D.new()
	spring_arm.name = "SpringArm3D"
	spring_arm.spring_length = 18.0
	spring_arm.position = Vector3(0.0, 5.0, 0.0)
	spring_arm.margin = 0.5
	spring_arm.collision_mask = (1 << (Obstacle.COLLISION_LAYER_OBSTACLE - 1)) | (1 << (Person.COLLISION_LAYER_PERSON - 1))
	drone.add_child(spring_arm)

	_drone_camera = DroneCamera.new()
	_drone_camera.name = "DroneCamera"
	_drone_camera.current = true
	_drone_camera.fov = camera.fov
	spring_arm.add_child(_drone_camera)

	# Disable free camera since drone camera is now current
	camera.current = false

	return drone

# ============================================================
#  ImGui Debug UI (loaded dynamically via imgui_debug_ui.gd)
# ============================================================

func _try_load_imgui_debug_ui() -> void:
	if not ResourceLoader.exists("res://assets/game/imgui_debug_ui.gd"):
		return
	var script = load("res://assets/game/imgui_debug_ui.gd")
	if script:
		_imgui_debug_ui = script.new(self)

func reset_to_defaults() -> void:
	if _default_cache.is_empty(): return

	camera.fov = _default_cache["fov"]
	_camera_fov[0] = camera.fov

	water.map_size = _default_cache["map_size"]
	water.mesh_quality = _default_cache["mesh_quality"]
	clipmap_tile_size = _default_cache["clipmap_tile"]

	water.updates_per_second = _default_cache["updates"]
	_updates_per_second[0] = water.updates_per_second

	water.update_textures = _default_cache["update_tex"]
	_update_textures[0] = water.update_textures

	$Water/WaterSprayEmitter.visible = _default_cache["sea_spray"]
	_is_sea_spray_visible[0] = _default_cache["sea_spray"]

	water.water_color = _default_cache["water_color"]
	_water_color = [water.water_color.r, water.water_color.g, water.water_color.b]

	water.foam_color = _default_cache["foam_color"]
	_foam_color = [water.foam_color.r, water.foam_color.g, water.foam_color.b]

	var c_color : Color = _default_cache["crest_color"]
	_crest_color = [c_color.r, c_color.g, c_color.b]
	water.get_active_material(0).set_shader_parameter("crest_color", c_color)

	_crest_glow_intensity[0] = _default_cache["crest_glow"]
	water.get_active_material(0).set_shader_parameter("crest_glow_intensity", _crest_glow_intensity[0])

	_aerated_foam_glow[0] = _default_cache["aerated_glow"]
	water.get_active_material(0).set_shader_parameter("aerated_foam_glow", _aerated_foam_glow[0])

	var original_cascades : Array[WaveCascadeParameters] = _default_cache["cascades"]
	for i in range(water.parameters.size()):
		var target : WaveCascadeParameters = water.parameters[i]
		var source : WaveCascadeParameters = original_cascades[i]

		target.tile_length = source.tile_length
		target._tile_length[0] = source.tile_length.x; target._tile_length[1] = source.tile_length.y
		target.displacement_scale = source.displacement_scale; target._displacement_scale[0] = source.displacement_scale
		target.normal_scale = source.normal_scale; target._normal_scale[0] = source.normal_scale
		target.wind_speed = source.wind_speed; target._wind_speed[0] = source.wind_speed
		target.wind_direction = source.wind_direction; target._wind_direction[0] = source.wind_direction
		target.fetch_length = source.fetch_length; target._fetch_length[0] = source.fetch_length
		target.swell = source.swell; target._swell[0] = source.swell
		target.spread = source.spread; target._spread[0] = source.spread
		target.detail = source.detail; target._detail[0] = source.detail
		target.whitecap = source.whitecap; target._whitecap[0] = source.whitecap
		target.foam_amount = source.foam_amount; target._foam_amount[0] = source.foam_amount

		target.should_generate_spectrum = true
