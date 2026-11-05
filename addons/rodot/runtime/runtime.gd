extends Node

const GodotBridge = preload("godot_bridge.gd")
const Attributes = preload("attributes.gd")
const InputActions = preload("input_actions.gd")
const LocalSaves = preload("local_saves.gd")
const DataStores = preload("data_store.gd")
const DataStoreHTTP = preload("data_store_http.gd")

var camera_controls := preload("camera_controls.gd").new()
var data_store_http := DataStoreHTTP.new()

var state: Object
var classes: Dictionary = {}
var properties: Dictionary = {}
var pending: Array[Node] = []
var objects: Dictionary = {}
var events: Array = []
var subscriptions: Dictionary = {}
var errors: Array[String] = []
var started := false
var tick: Callable
var physics_tick: Callable
var refresh_scene: Callable
var scene_id := 0
var scene_change_pending := false
var script_scopes: Dictionary = {}
var removed_scripts: Dictionary = {}
var services: Dictionary = {}
var service_types: Dictionary = {}

func _ready() -> void:
	classes = _read_json("res://addons/rodot/api/classes.json")
	properties = _read_json("res://addons/rodot/api/properties.json")
	service_types = _read_json("res://addons/rodot/api/services.json")
	var service_path: String = ProjectSettings.get_setting("rodot/api/services", "")
	if not service_path.is_empty(): service_types.merge(_read_json(service_path), true)
	for kind in ["classes", "properties"]:
		var path: String = ProjectSettings.get_setting("rodot/api/" + kind, "")
		if not path.is_empty():
			if kind == "classes":
				classes.merge(_read_json(path), true)
			else:
				properties.merge(_read_json(path), true)
	if not ClassDB.class_exists("LuaState"):
		_report("Rodot's bundled native Luau runtime could not load. Godot 4.5 or later is required.")
		return
	state = ClassDB.instantiate("LuaState")
	state.open_libs()
	state.push_callable(_bridge)
	state.set_global("__rodot_bridge")
	state.push_variant(_read_json("res://addons/rodot/api/enums.json"))
	state.set_global("__rodot_enums")
	if not execute(FileAccess.get_file_as_string("res://addons/rodot/runtime/bootstrap.luau"), "@Rodot/bootstrap"):
		return
	state.get_global("__rodot_tick")
	tick = state.to_callable(-1)
	state.pop(1)
	state.get_global("__rodot_physics")
	physics_tick = state.to_callable(-1)
	state.pop(1)
	state.get_global("__rodot_refresh_scene")
	refresh_scene = state.to_callable(-1)
	state.pop(1)
	get_tree().node_removed.connect(_node_removed)
	started = true

func _physics_process(delta: float) -> void:
	if not started: return
	_sync_scene()
	physics_tick.call(delta)

func _node_removed(node: Node) -> void:
	var id := node.get_instance_id()
	if script_scopes.has(id): removed_scripts[id] = true

func _sync_scene() -> void:
	var scene := get_tree().current_scene
	var next_id := scene.get_instance_id() if is_instance_valid(scene) else 0
	var retired: Array = []
	for id in removed_scripts:
		var node := _node(id)
		if node == null or not node.is_inside_tree():
			retired.append(id)
			script_scopes.erase(id)
	removed_scripts.clear()
	if scene_id == next_id and retired.is_empty(): return
	if scene_id != next_id:
		if scene_id != 0: camera_controls.clear()
		scene_id = next_id
		for id in objects.keys():
			if _node(id) == null: objects.erase(id)
		for token in subscriptions.keys():
			if _node(token.get_slice(":", 0).to_int()) == null: subscriptions.erase(token)
		if scene != null: events.append([0, "scene:changed", [scene]])
	refresh_scene.call(scene_id, retired)

func _read_json(path: String) -> Dictionary:
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Dictionary:
		return data
	_report("Invalid Rodot registry: " + path)
	return {}

func register_script(node: Node) -> void:
	if not pending.has(node):
		pending.append(node)

func execute(source: String, chunk: String) -> bool:
	if state == null:
		return false
	var top: int = state.get_top()
	var status: int = state.do_string(source, chunk, 0, 0, 0)
	if status != 0:
		_report(state.to_string_inplace(-1))
	state.set_top(top)
	return status == 0

func _process(delta: float) -> void:
	if not started:
		return
	_sync_scene()
	var batch := pending.duplicate()
	pending.clear()
	for node in batch:
		if not is_instance_valid(node) or not node.is_inside_tree() or not node.is_module_script(): continue
		if node.source.is_empty() or not FileAccess.file_exists(node.source): continue
		_remember(node)
		var source := FileAccess.get_file_as_string(node.source)
		execute("__rodot_register_module(function() " + source + "\nend, " + str(node.get_instance_id()) + ")", "@" + node.source)
	for node in batch:
		if not is_instance_valid(node) or not node.is_inside_tree() or node.is_module_script() or not node.can_run():
			continue
		var source: String = FileAccess.get_file_as_string(node.source)
		if source.is_empty():
			_report("Empty or missing Luau source: " + node.source)
			continue
		_remember(node)
		execute("__rodot_execute(function() " + source + "\nend, " + str(node.get_instance_id()) + ")", "@" + node.source)
	InputActions.collect_events(events)
	tick.call(delta)
	camera_controls.update(delta, events)

func _report(message: String, path := "", line := 0) -> void:
	errors.append(message)
	push_error("Rodot: " + message)
	if not EngineDebugger.is_active(): return
	if path.is_empty():
		var location := RegEx.new()
		location.compile("(res://[^\\r\\n]+?\\.luau):(\\d+)")
		var found := location.search(message)
		if found != null:
			path = found.get_string(1)
			line = found.get_string(2).to_int()
	EngineDebugger.send_message("rodot:luau_error", [path, line, message])

func _remember(node: Node) -> Dictionary:
	objects[node.get_instance_id()] = node
	return {"__type": "Instance", "id": node.get_instance_id()}

func _node(id: int) -> Node:
	var value = instance_from_id(id)
	return value if is_instance_valid(value) and value is Node and not value.is_queued_for_deletion() else null

func _fail(message: String) -> Dictionary:
	return {"__error": message}

func _bridge(op: String, args: Array) -> Variant:
	var value = _dispatch(op, args)
	if value is Dictionary and value.has("__error"):
		return {"error": value.__error}
	return {"value": _encode(value)}

func _dispatch(op: String, args: Array) -> Variant:
	match op:
		"world":
			return get_tree().current_scene
		"tagged":
			if not _valid_tag(args.front() if not args.is_empty() else null): return _fail("Expected a nonblank tag string that does not start with an underscore")
			return get_tree().get_nodes_in_group(args[0]).filter(func(member: Node): return not member.is_queued_for_deletion())
		"track_script":
			if _node(int(args[0])) != null: script_scopes[int(args[0])] = true
			return null
		"change_scene":
			return _queue_scene(_decode(args[0]))
		"reload_scene":
			var scene := get_tree().current_scene
			return _queue_scene(scene.scene_file_path if scene != null else "")
		"local_save":
			return LocalSaves.access(str(args[0]), args[1] if args.size() > 1 else null, args[2] if args.size() > 2 else null)
		"data_store":
			var operation := str(args[0])
			if operation == "default": return int(ProjectSettings.get_setting(DataStoreHTTP.DEFAULT, 0))
			var backend := int(args[1])
			if backend < 0 or backend > 2: return _fail("Unknown DataStore backend")
			if backend == 0 or operation == "validate": return DataStores.access(operation, args.slice(2))
			return data_store_http.start(self, backend, operation, args.slice(2), _data_store_completed)
		"errors":
			_report(str(args[0]), str(args[1]) if args.size() > 1 else "", int(args[2]) if args.size() > 2 else 0)
			return null
		"events":
			var result := events.duplicate()
			events.clear()
			return result
		"input":
			return Input.is_physical_key_pressed(int(args[0]))
		"input_action":
			return InputActions.query(str(args[0]), args.slice(1))
		"camera_control":
			var scene := get_tree().current_scene
			var viewport := scene.get_viewport() if scene != null else get_viewport()
			return camera_controls.command(str(args[0]), _decode(args[1]), viewport)
		"cframe_lerp":
			var a: Transform3D = _decode(args[0])
			var b: Transform3D = _decode(args[1])
			return a.interpolate_with(b, float(args[2]))
		"create":
			return _create(str(args[0]))
		"run_gdscript":
			return GodotBridge.run_gdscript(_decode(args[0]), get_tree().current_scene, _node(int(args[1])), _decode(args[2]))
		"instantiate_scene":
			return _instantiate_scene(_decode(args[0]), args[1] if args.size() > 1 else null)
		"service":
			var name: String = args[0]
			if not service_types.has(name): return _fail("Service is not implemented: " + name)
			if not services.has(name):
				var spec: Dictionary = service_types[name]
				var native: String = spec.node
				if not ClassDB.class_exists(native) or not ClassDB.can_instantiate(native) or not ClassDB.is_parent_class(native, "Node"):
					return _fail("Invalid service class: " + native)
				var service: Node = ClassDB.instantiate(native)
				service.name = name
				service.set_meta("rodot_class", name)
				if not spec.get("detached", false): add_child(service)
				services[name] = service
			return services[name]
		"json_encode":
			return JSON.stringify(args[0])
		"json_decode":
			var parser := JSON.new()
			if parser.parse(str(args[0])) != OK: return _fail(parser.get_error_message())
			return parser.data
		"guid":
			var bytes := Crypto.new().generate_random_bytes(16)
			bytes[6] = (bytes[6] & 15) | 64
			bytes[8] = (bytes[8] & 63) | 128
			var hex := bytes.hex_encode()
			return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20)]
	var node := _node(int(args[0]))
	if node == null:
		return _fail("Instance has been destroyed")
	match op:
		"get":
			return _get_property(node, str(args[1]))
		"raycast":
			if node != get_tree().current_scene: return _fail("Raycast is available on workspace")
			return preload("raycast.gd").cast(node, _decode(args[1]), _decode(args[2]), _decode(args[3]) if args.size() > 3 else null)
		"set":
			var result = _set_property(node, str(args[1]), _decode(args[2] if args.size() > 2 else null))
			if result == null:
				events.append([node.get_instance_id(), "Changed", [args[1]]])
				events.append([node.get_instance_id(), "property:" + str(args[1]), []])
			return result
		"children":
			return node.get_children().filter(func(child): return not child.has_meta("rodot_internal"))
		"descendants":
			return _descendants(node)
		"find":
			var children: Array = _descendants(node) if bool(args[2]) else node.get_children()
			for child in children:
				if str(child.name) == args[1] and not child.has_meta("rodot_internal"): return child
			return null
		"destroy":
			var id := node.get_instance_id()
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.queue_free()
			objects.erase(id)
			return null
		"clone":
			if not node.get_meta("rodot_archivable", true): return null
			var copy := node.duplicate()
			_prune_unarchivable(copy)
			_unique_resources(copy)
			_remember(copy)
			return copy
		"isa":
			var alias: String = node.get_meta("rodot_class", node.get_class())
			return alias == args[1] or args[1] == "Instance" or (args[1] == "BasePart" and alias == "Part") or node.is_class(str(args[1]))
		"fullname":
			var names: Array[String] = [str(node.name)]
			var parent := node.get_parent()
			while parent != null and parent != get_tree().root:
				names.push_front(str(parent.name))
				parent = parent.get_parent()
			return ".".join(names)
		"attribute_get":
			var key := Attributes.PREFIX + str(args[1])
			return node.get_meta(key) if node.has_meta(key) else null
		"attributes":
			return Attributes.all(node)
		"tags":
			var tags: Array[String] = []
			for group in node.get_groups():
				if _valid_tag(str(group)): tags.append(str(group))
			return tags
		"tag_add", "tag_remove", "tag_has":
			if not _valid_tag(args[1] if args.size() > 1 else null): return _fail("Expected a nonblank tag string that does not start with an underscore")
			var tag := StringName(args[1])
			var has_tag := node.is_in_group(tag)
			if op == "tag_has": return has_tag
			if op == "tag_add" and not has_tag: node.add_to_group(tag, true)
			if op == "tag_remove" and has_tag: node.remove_from_group(tag)
			return null
		"attribute_set":
			if not Attributes.valid_name(args[1]): return _fail("Attribute names use letters, digits, and underscores")
			var key := Attributes.PREFIX + str(args[1])
			var before = node.get_meta(key) if node.has_meta(key) else null
			if args.size() < 3 or args[2] == null:
				if node.has_meta(key): node.remove_meta(key)
			else:
				node.set_meta(key, _decode(args[2]))
			var after = node.get_meta(key) if node.has_meta(key) else null
			if before != after:
				events.append([node.get_instance_id(), "attribute:" + str(args[1]), []])
			return null
		"subscribe":
			return _subscribe(node, str(args[1]))
		"call":
			var method := str(args[1])
			if not node.has_method(method): method = method.to_snake_case()
			return GodotBridge.invoke(node, method, _decode(args[2]))
	return _fail("Unknown bridge operation: " + op)

func _valid_tag(tag: Variant) -> bool:
	return tag is String and not tag.strip_edges().is_empty() and not tag.begins_with("_")

func _descendants(node: Node) -> Array:
	var result: Array = []
	for child in node.get_children():
		if not child.has_meta("rodot_internal"):
			result.append(child)
			result.append_array(_descendants(child))
	return result

func _prune_unarchivable(node: Node) -> void:
	for child in node.get_children():
		if not child.get_meta("rodot_archivable", true): child.free()
		else: _prune_unarchivable(child)

func _unique_resources(node: Node) -> void:
	if node is MeshInstance3D:
		if node.mesh != null: node.mesh = node.mesh.duplicate()
		if node.material_override != null: node.material_override = node.material_override.duplicate()
	if node is CollisionShape3D and node.shape != null: node.shape = node.shape.duplicate()
	for child in node.get_children(true): _unique_resources(child)

func _instantiate_scene(input: Variant, parent_value: Variant) -> Variant:
	var parent = _decode(parent_value)
	if parent_value != null and not parent is Node: return _fail("Instantiate expects a live parent node or nil")
	var path := GodotBridge.project_path(input)
	if path.is_empty() or not ResourceLoader.exists(path, "PackedScene"):
		return _fail("Instantiate expects a saved project scene")
	var packed := load(path) as PackedScene
	if packed == null or not packed.can_instantiate(): return _fail("Could not load the scene: " + path)
	var node := packed.instantiate()
	if node == null: return _fail("Could not instantiate the scene: " + path)
	if parent != null:
		parent.add_child(node, true)
		events.append([parent.get_instance_id(), "ChildAdded", [node]])
	return node

func _data_store_completed(id: int, reply: Dictionary) -> void:
	events.append([0, "data_store:result", [id, reply]])

func _queue_scene(input: Variant) -> Variant:
	if scene_change_pending: return _fail("A scene change is already queued")
	var path := GodotBridge.project_path(input)
	if path.is_empty() or not ResourceLoader.exists(path, "PackedScene"):
		return _fail("ChangeScene expects a saved project scene")
	var packed := load(path) as PackedScene
	if packed == null or not packed.can_instantiate(): return _fail("Could not load the scene: " + path)
	scene_change_pending = true
	_apply_scene.call_deferred(packed)
	return true

func _apply_scene(packed: PackedScene) -> void:
	scene_change_pending = false
	if not is_inside_tree(): return
	var result := get_tree().change_scene_to_packed(packed)
	if result != OK: _report("Could not switch scene: " + error_string(result))

func _create(alias: String) -> Variant:
	var native_only := alias.begins_with("Godot.")
	var spec: Dictionary = {"node": alias.trim_prefix("Godot.")} if native_only else classes.get(alias, {"node": alias})
	var native: String = spec.node
	if not native_only and not classes.has(alias) and not ClassDB.class_exists(native):
		var registry := GodotBridge.project_node_classes()
		if registry.has(alias) and not GodotBridge.native_base(alias, registry).is_empty():
			var resource := load(registry[alias].path) as GDScript
			if resource == null or not resource.can_instantiate(): return _fail("Could not instantiate GDScript class: " + alias)
			for method in resource.get_script_method_list():
				if method.name == "_init" and method.args.size() > method.default_args.size(): return _fail("GDScript class requires constructor arguments: " + alias)
			var scripted: Node = resource.new()
			scripted.name = alias
			scripted.set_meta("rodot_class", alias)
			_remember(scripted)
			return scripted
	if not ClassDB.class_exists(native) or not ClassDB.can_instantiate(native) or not ClassDB.is_parent_class(native, "Node"):
		return _fail("Unknown or non-Node class: " + alias)
	var node: Node = ClassDB.instantiate(native)
	if spec.has("script"):
		var adapter = load(str(spec.script))
		if not adapter is Script or not adapter.can_instantiate() or not node.is_class(adapter.get_instance_base_type()):
			node.free()
			return _fail("Invalid class adapter: " + alias)
		node.set_script(adapter)
	node.name = native if native_only else alias
	node.set_meta("rodot_class", node.name)
	if spec.has("value"):
		node.set_meta("rodot_value", _decode(spec.value))
	if spec.get("factory", "") == "part":
		node.freeze = false
		node.contact_monitor = true
		node.max_contacts_reported = 8
		var mesh := MeshInstance3D.new()
		mesh.name = "RodotMesh"
		mesh.set_meta("rodot_internal", true)
		mesh.mesh = BoxMesh.new()
		mesh.mesh.size = Vector3(4, 1, 2)
		mesh.material_override = StandardMaterial3D.new()
		node.add_child(mesh)
		var collision := CollisionShape3D.new()
		collision.name = "RodotCollision"
		collision.set_meta("rodot_internal", true)
		collision.shape = BoxShape3D.new()
		collision.shape.size = Vector3(4, 1, 2)
		node.add_child(collision)
	_remember(node)
	return node

func _has_property(node: Object, key: String) -> bool:
	for prop in node.get_property_list():
		if prop.name == key:
			return true
	return false

func _material(node: Node) -> StandardMaterial3D:
	var mesh = node.get_node_or_null("RodotMesh")
	if mesh is MeshInstance3D:
		return mesh.material_override
	return null

func _get_property(node: Node, key: String) -> Variant:
	match key:
		"Archivable", "archivable": return node.get_meta("rodot_archivable", true)
		"RodotLocked": return bool(node.get_meta("_edit_lock_", false))
		"UniqueId": return "%016x" % node.get_instance_id()
		"className": return node.get_meta("rodot_class", node.get_class())
	if node.has_method("_rodot_get"):
		var adapted: Dictionary = node.call("_rodot_get", key)
		if adapted.get("handled", false): return adapted.get("value")
	var spec: Dictionary = properties.get(key, {"kind": "native", "property": key.to_snake_case()})
	match spec.kind:
		"class": return node.get_meta("rodot_class", node.get_class())
		"parent": return node.get_parent()
		"value":
			if classes.get(node.get_meta("rodot_class", ""), {}).has("value"):
				return node.get_meta("rodot_value") if node.has_meta("rodot_value") else null
		"position":
			if node is Node3D: return node.global_position if node.is_inside_tree() else node.position
			if node is Control: return node.position
		"transform":
			if node is Node3D: return node.global_transform if node.is_inside_tree() else node.transform
		"size":
			var mesh = node.get_node_or_null("RodotMesh")
			if mesh != null: return mesh.mesh.size
			if node is Control: return node.size
		"color":
			var material := _material(node)
			if material != null: return material.albedo_color
			if node is Light3D: return node.light_color
		"transparency":
			var material := _material(node)
			if material != null: return 1.0 - material.albedo_color.a
		"collision":
			if node is PhysicsBody3D: return node.collision_layer != 0
		"native":
			var field := GodotBridge.property_info(node, [key, spec.property])
			if not field.is_empty(): return node.get(field.name)
	var field := GodotBridge.property_info(node, [key, key.to_snake_case()])
	if not field.is_empty(): return node.get(field.name)
	var child := node.get_node_or_null(NodePath(key)) if not key.contains("/") and key != ".." and key != "." else null
	if child != null and not child.has_meta("rodot_internal"):
		return child
	var method := GodotBridge.member_name(node, key)
	if not method.is_empty(): return {"__type": "GodotMethod", "Name": method}
	var signal_name := GodotBridge.member_name(node, key, true)
	if not signal_name.is_empty(): return {"__type": "GodotSignal", "Name": signal_name}
	return _fail("%s is not a property or child of %s" % [key, node.name])

func _set_property(node: Node, key: String, value: Variant) -> Variant:
	match key:
		"Archivable", "archivable":
			if not value is bool: return _fail("Archivable must be a boolean")
			if _has_property(node, "archivable"): node.set("archivable", value)
			else: node.set_meta("rodot_archivable", value)
			return null
		"RodotLocked":
			if not value is bool: return _fail("RodotLocked must be a boolean")
			if _has_property(node, "rodot_locked"): node.set("rodot_locked", value)
			elif node.get_meta("rodot_class", "") == "Part" and _has_property(node, "locked"): node.set("locked", value)
			elif value: node.set_meta("_edit_lock_", true)
			elif node.has_meta("_edit_lock_"): node.remove_meta("_edit_lock_")
			return null
		"UniqueId", "className": return _fail(key + " is read-only")
	if node.has_method("_rodot_set"):
		var adapted: Dictionary = node.call("_rodot_set", key, value)
		if adapted.get("handled", false): return _fail(adapted.error) if adapted.has("error") else null
	var spec: Dictionary = properties.get(key, {"kind": "native", "property": key.to_snake_case()})
	if spec.get("readonly", false): return _fail(key + " is read-only")
	match spec.kind:
		"parent":
			if value != null and not value is Node: return _fail("Parent must be an Instance or nil")
			if value == node or (value != null and node.is_ancestor_of(value)): return _fail("Parent would create a cycle")
			if node.get_parent() == value: return null
			if node.get_parent() != null:
				var old_parent := node.get_parent()
				old_parent.remove_child(node)
				events.append([old_parent.get_instance_id(), "ChildRemoved", [node]])
			if value != null:
				value.add_child(node)
				events.append([value.get_instance_id(), "ChildAdded", [node]])
			return null
		"value":
			if classes.get(node.get_meta("rodot_class", ""), {}).has("value"):
				node.set_meta("rodot_value", value)
				return null
		"position":
			if node is Node3D and value is Vector3:
				if node.is_inside_tree(): node.global_position = value
				else: node.position = value
				return null
			if node is Control and value is Vector2:
				node.position = value
				return null
		"transform":
			if node is Node3D and value is Transform3D:
				if node.is_inside_tree(): node.global_transform = value
				else: node.transform = value
				return null
		"size":
			var mesh = node.get_node_or_null("RodotMesh")
			if mesh != null and value is Vector3 and value.x > 0 and value.y > 0 and value.z > 0:
				mesh.mesh = mesh.mesh.duplicate()
				mesh.mesh.size = value
				var shape = node.get_node("RodotCollision")
				shape.shape = shape.shape.duplicate()
				shape.shape.size = value
				return null
			if node is Control and value is Vector2:
				node.size = value
				return null
		"color":
			if value is Color:
				var material := _material(node)
				if material != null:
					var mesh := node.get_node("RodotMesh")
					material = material.duplicate()
					value.a = material.albedo_color.a
					material.albedo_color = value
					mesh.material_override = material
					return null
				if node is Light3D:
					node.light_color = value
					return null
		"transparency":
			var material := _material(node)
			if material != null and (value is float or value is int):
				material = material.duplicate()
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if value > 0 else BaseMaterial3D.TRANSPARENCY_DISABLED
				material.albedo_color.a = 1.0 - clampf(value, 0, 1)
				node.get_node("RodotMesh").material_override = material
				return null
		"collision":
			if node is PhysicsBody3D and value is bool:
				node.collision_layer = 1 if value else 0
				node.collision_mask = 1 if value else 0
				return null
		"native":
			var field := GodotBridge.property_info(node, [key, spec.property])
			if not field.is_empty(): return GodotBridge.set_property(node, field, value)
	var field := GodotBridge.property_info(node, [key, key.to_snake_case()])
	if not field.is_empty(): return GodotBridge.set_property(node, field, value)
	return _fail("Unsupported property or value: " + key)

func _subscribe(node: Node, event: String) -> Variant:
	var token := str(node.get_instance_id()) + ":" + event
	if subscriptions.has(token): return null
	var native: String = {"Touched": "body_entered", "ChildAdded": "child_entered_tree", "ChildRemoved": "child_exiting_tree", "MouseButton1Click": "pressed"}.get(event, GodotBridge.member_name(node, event, true))
	if not node.has_signal(native): return _fail("Unknown signal: " + event)
	var count := 0
	for info in node.get_signal_list():
		if info.name == native: count = info.args.size()
	var id := node.get_instance_id()
	var callback: Callable
	match count:
		0: callback = func(): events.append([id, event, []])
		1: callback = func(a): events.append([id, event, [a]])
		2: callback = func(a, b): events.append([id, event, [a, b]])
		_: return _fail("Use Godot signals with up to two arguments")
	node.connect(native, callback)
	subscriptions[token] = callback
	return null

func _encode(value: Variant) -> Variant:
	if typeof(value) == TYPE_OBJECT and not is_instance_valid(value): return null
	if value is Node: return _remember(value)
	if value is NodePath: return {"__type": "Path", "Value": str(value)}
	if value is StringName: return str(value)
	if value is Vector3: return {"__type": "Vector3", "X": value.x, "Y": value.y, "Z": value.z}
	if value is Vector2: return {"__type": "Vector2", "X": value.x, "Y": value.y}
	if value is Color: return {"__type": "Color3", "R": value.r, "G": value.g, "B": value.b}
	if value is Transform3D:
		return {"__type": "CFrame", "components": [value.origin.x, value.origin.y, value.origin.z, value.basis.x.x, value.basis.y.x, value.basis.z.x, value.basis.x.y, value.basis.y.y, value.basis.z.y, value.basis.x.z, value.basis.y.z, value.basis.z.z]}
	if value is Array: return value.map(_encode)
	if value is Dictionary:
		var result := {}
		for key in value: result[key] = _encode(value[key])
		return result
	return value

func _decode(value: Variant) -> Variant:
	if value is Array: return value.map(_decode)
	if not value is Dictionary: return value
	match value.get("__type", ""):
		"GodotNil": return null
		"Path": return NodePath(value.Value)
		"Instance": return _node(int(value.id))
		"Vector3": return Vector3(value.X, value.Y, value.Z)
		"Vector2": return Vector2(value.X, value.Y)
		"Color3": return Color(value.R, value.G, value.B)
		"CFrame":
			var c: Array = value.components
			return Transform3D(Basis(Vector3(c[3], c[6], c[9]), Vector3(c[4], c[7], c[10]), Vector3(c[5], c[8], c[11])), Vector3(c[0], c[1], c[2]))
	if value.has("__type") and value.__type != "RaycastParams": return value
	var result := {}
	for key in value: result[key] = _decode(value[key])
	return result

func _exit_tree() -> void:
	camera_controls.clear()
	tick = Callable()
	physics_tick = Callable()
	refresh_scene = Callable()
	for node in objects.values():
		if is_instance_valid(node) and node.get_parent() == null:
			node.free()
	objects.clear()
	state = null
