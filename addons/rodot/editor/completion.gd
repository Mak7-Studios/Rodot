@tool
extends RefCounted

const GodotBridge = preload("../runtime/godot_bridge.gd")

var properties: Dictionary
var classes: Dictionary
var services: Dictionary
var enums: Dictionary
var members: Dictionary = {}
var globals: Dictionary = {}
var scene_root: Node
var script_node: Node
var source_path := ""
var native_nodes: Array[String] = []

func _init() -> void:
	properties = _json("res://addons/rodot/api/properties.json")
	classes = _json("res://addons/rodot/api/classes.json")
	services = _json("res://addons/rodot/api/services.json")
	enums = _json("res://addons/rodot/api/enums.json")
	for kind in ["properties", "classes", "services"]:
		var path: String = ProjectSettings.get_setting("rodot/api/" + kind, "")
		if not path.is_empty(): get(kind).merge(_json(path), true)
	_build_catalog()
	for native in ClassDB.get_class_list():
		if ClassDB.is_parent_class(native, "Node") and ClassDB.can_instantiate(native): native_nodes.append(str(native))

func _json(path: String) -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}

func set_context(root_node: Node, path: String, selected: Node = null) -> void:
	scene_root = root_node
	source_path = path
	script_node = selected if _is_runner(selected, path) else _find_runner(root_node, path)

func _is_runner(node: Node, path: String) -> bool:
	return is_instance_valid(node) and node.has_method("is_module_script") and node.source == path

func _find_runner(node: Node, path: String) -> Node:
	if not is_instance_valid(node): return null
	if _is_runner(node, path): return node
	for child in node.get_children():
		var found := _find_runner(child, path)
		if found != null: return found
	return null

func _entry(name: String, kind: int, type_name: String = "", signature: String = "", is_static: bool = false) -> Dictionary:
	return {"name": name, "kind": kind, "type": type_name, "signature": signature, "static": is_static}

func _add(owner: String, name: String, kind: int, type_name := "", signature := "", is_static := false) -> void:
	if not members.has(owner): members[owner] = {}
	members[owner][name] = _entry(name, kind, type_name, signature, is_static)

func _build_catalog() -> void:
	var bootstrap := FileAccess.get_file_as_string("res://addons/rodot/runtime/bootstrap.luau")
	var aliases := {"instanceMethods": ["Instance"], "vectorMethods": ["Vector2", "Vector3"], "colorMethods": ["Color3"], "cfMethods": ["CFrame"], "rayMethods": ["Ray"], "raycastParamsMethods": ["RaycastParams"], "runService": ["RunService"], "game": ["Game"], "task": ["task"]}
	aliases.InputService = ["InputService", "UserInputService"]
	var functions := RegEx.new()
	functions.compile("(?m)^function ([A-Za-z_][A-Za-z_0-9]*)([.:])([A-Za-z_][A-Za-z_0-9]*)\\(([^\\n)]*)\\)")
	for match_value in functions.search_all(bootstrap):
		var owner := match_value.get_string(1)
		if owner.ends_with("Meta") or owner == "Signal" and match_value.get_string(3) == "new": continue
		var owners: Array = aliases.get(owner, [owner])
		var is_static := match_value.get_string(2) == "." and not aliases.has(owner)
		for target in owners:
			_add(target, match_value.get_string(3), CodeEdit.KIND_FUNCTION, "", match_value.get_string(3) + "(" + match_value.get_string(4) + ")", is_static)
	var constructors := RegEx.new()
	constructors.compile('(?m)^([A-Za-z][A-Za-z0-9]*) = (?:recordType|makeVectorType|integerVector|sequence)\\("')
	for match_value in constructors.search_all(bootstrap):
		_add(match_value.get_string(1), "new", CodeEdit.KIND_FUNCTION, match_value.get_string(1), "new(...)", true)
	var names := ["World", "workspace", "game", "script", "Godot", "task", "Instance", "Enum", "Vector2", "Vector3", "Vector2int16", "Vector3int16", "Color3", "CFrame", "UDim", "UDim2", "Region3", "Rect", "Ray", "NumberRange", "NumberSequence", "NumberSequenceKeypoint", "ColorSequence", "ColorSequenceKeypoint", "PhysicalProperties", "Random", "TweenInfo"]
	names.append_array(["Path", "RaycastParams"])
	for name in names: globals[name] = _entry(name, CodeEdit.KIND_CLASS)
	for name in ["print", "warn", "require", "typeof", "type", "tostring", "tonumber", "assert", "error", "pcall", "xpcall", "pairs", "ipairs", "next", "select", "unpack", "getmetatable", "setmetatable", "rawget", "rawset", "rawequal", "getfenv", "setfenv", "time", "wait", "spawn", "delay"]:
		globals[name] = _entry(name, CodeEdit.KIND_FUNCTION, "", name + "(...)")
	var libraries := _json("res://addons/rodot/editor/libraries.json")
	for library in libraries:
		globals[library] = _entry(library, CodeEdit.KIND_CLASS)
		for signature in libraries[library]:
			_add(library, signature.get_slice("(", 0), CodeEdit.KIND_FUNCTION, "", signature, true)
	for constant in ["pi", "huge"]: _add("math", constant, CodeEdit.KIND_CONSTANT, "number", "", true)
	for type_name in ["Vector2", "Vector3", "Vector2int16", "Vector3int16"]:
		for axis in (["X", "Y", "Z"] if type_name.contains("3") else ["X", "Y"]): _add(type_name, axis, CodeEdit.KIND_MEMBER, "number")
		if not type_name.ends_with("int16"):
			_add(type_name, "Magnitude", CodeEdit.KIND_MEMBER, "number")
			_add(type_name, "Unit", CodeEdit.KIND_MEMBER, type_name)
			for constant in ["zero", "one"]: _add(type_name, constant, CodeEdit.KIND_CONSTANT, type_name, "", true)
	for field in ["R", "G", "B"]: _add("Color3", field, CodeEdit.KIND_MEMBER, "number")
	for field in ["Position", "RightVector", "UpVector", "LookVector"]: _add("CFrame", field, CodeEdit.KIND_MEMBER, "Vector3")
	_add("CFrame", "Rotation", CodeEdit.KIND_MEMBER, "CFrame")
	_add("CFrame", "identity", CodeEdit.KIND_CONSTANT, "CFrame", "", true)
	for field in ["X", "Y", "Z"]: _add("CFrame", field, CodeEdit.KIND_MEMBER, "number")
	var fields := {"UDim": {"Scale": "number", "Offset": "number"}, "UDim2": {"X": "UDim", "Y": "UDim"}, "Rect": {"Min": "Vector2", "Max": "Vector2", "Width": "number", "Height": "number"}, "Ray": {"Origin": "Vector3", "Direction": "Vector3"}, "Region3": {"CFrame": "CFrame", "Size": "Vector3"}, "NumberRange": {"Min": "number", "Max": "number"}, "NumberSequenceKeypoint": {"Time": "number", "Value": "number", "Envelope": "number"}, "ColorSequenceKeypoint": {"Time": "number", "Value": "Color3"}}
	for owner in fields:
		for field in fields[owner]: _add(owner, field, CodeEdit.KIND_MEMBER, fields[owner][field])
	_add("Region3", "ExpandToGrid", CodeEdit.KIND_FUNCTION, "Region3", "ExpandToGrid(resolution)")
	_add("Workspace", "Raycast", CodeEdit.KIND_FUNCTION, "RaycastResult", "Raycast(origin, direction, params?)")
	var result_fields := {"Instance": "Instance", "Position": "Vector3", "Normal": "Vector3", "Distance": "number", "Material": "EnumItem"}
	for field in result_fields:
		_add("RaycastResult", field, CodeEdit.KIND_MEMBER, result_fields[field])
	for field in ["FilterType", "FilterDescendantsInstances", "IncludeInstances", "ExcludeInstances", "CollisionGroup", "CollisionMask", "RespectCanCollide", "IgnoreWater", "IncludeAreas"]:
		_add("RaycastParams", field, CodeEdit.KIND_MEMBER)
	_add("Path", "Value", CodeEdit.KIND_MEMBER, "string")
	_add("Godot", "Instantiate", CodeEdit.KIND_FUNCTION, "Instance", "Instantiate(path, parent?)", true)
	_add("Godot", "ChangeScene", CodeEdit.KIND_FUNCTION, "boolean", "ChangeScene(path)", true)
	for owner in ["NumberSequence", "ColorSequence"]: _add(owner, "Keypoints", CodeEdit.KIND_MEMBER, "table")
	for signature in ["NextNumber(min, max)", "NextInteger(min, max)", "NextUnitVector()"]: _add("Random", signature.get_slice("(", 0), CodeEdit.KIND_FUNCTION, "", signature)
	for field in ["Ready", "Process", "PhysicsProcess", "SceneChanged"]: _add("Godot", field, CodeEdit.KIND_SIGNAL, "Signal", "", true)
	_add("Godot", "Save", CodeEdit.KIND_MEMBER, "LocalSave", "", true)
	_add("DataStoreService", "GetDataStore", CodeEdit.KIND_FUNCTION, "DataStore", "GetDataStore(name, scope?, backend?)")
	_add("DataStore", "Name", CodeEdit.KIND_MEMBER, "string")
	_add("DataStore", "Scope", CodeEdit.KIND_MEMBER, "string")
	_add("DataStore", "Type", CodeEdit.KIND_MEMBER, "Enum.DataStoreType")
	_add("Godot", "Input", CodeEdit.KIND_MEMBER, "InputService", "", true)
	_add("Godot", "Camera", CodeEdit.KIND_MEMBER, "CameraControls", "", true)
	for service in ["InputService", "UserInputService"]:
		for event in ["ActionPressed", "ActionReleased"]: _add(service, event, CodeEdit.KIND_SIGNAL, "Signal")
	_add("CameraControls", "BlendFinished", CodeEdit.KIND_SIGNAL, "Signal")
	_add("CameraControls", "GetCurrent", CodeEdit.KIND_FUNCTION, "Camera3D", "GetCurrent()")
	for field in ["Heartbeat", "RenderStepped", "Stepped"]: _add("RunService", field, CodeEdit.KIND_SIGNAL, "Signal")
	for signal_name in ["Changed", "ChildAdded", "ChildRemoved"]: _add("Instance", signal_name, CodeEdit.KIND_SIGNAL, "Signal")
	for signature in ["Play()", "Pause()", "Cancel()"]: _add("Tween", signature.get_slice("(", 0), CodeEdit.KIND_FUNCTION, "", signature)
	_add("Tween", "Completed", CodeEdit.KIND_SIGNAL, "Signal")
	_add("Tween", "PlaybackState", CodeEdit.KIND_MEMBER, "EnumItem")
	_add("Connection", "Connected", CodeEdit.KIND_MEMBER, "boolean")
	_add("Connection", "Disconnect", CodeEdit.KIND_FUNCTION, "", "Disconnect()")
	for owner in ["Signal", "Instance", "TweenService", "Game"]:
		var returns := {"Connect": "Connection", "Once": "Connection", "GetPropertyChangedSignal": "Signal", "GetSignal": "Signal", "FindFirstChild": "Instance", "WaitForChild": "Instance", "Clone": "Instance", "Create": "Tween"}
		for method in members.get(owner, {}):
			if returns.has(method): members[owner][method].type = returns[method]

func _context(type_name: String, node: Node = null, is_static := false) -> Dictionary:
	return {"type": type_name, "node": node, "static": is_static}

func resolve(expression: String, source: String, depth := 0) -> Dictionary:
	if depth > 8: return _context("Instance")
	expression = expression.strip_edges()
	var service_match := RegEx.new()
	service_match.compile('^game:GetService\\(["\']([^"\']+)["\']\\)(.*)$')
	var found := service_match.search(expression)
	if found:
		var service := _context(found.get_string(1))
		var tail := found.get_string(2)
		if tail.begins_with(":") and tail.contains("("):
			return _method_return(service, tail.trim_prefix(":").get_slice("(", 0))
		return _chain(service, tail)
	var method_call := RegEx.new()
	method_call.compile("^([A-Za-z_][A-Za-z_0-9.]*)[:]([A-Za-z_][A-Za-z_0-9]*)\\(")
	found = method_call.search(expression)
	if found: return _method_return(resolve(found.get_string(1), source, depth + 1), found.get_string(2))
	var constructor := RegEx.new()
	constructor.compile('^Instance\\.new\\(["\']([^"\']+)["\']')
	found = constructor.search(expression)
	if found: return _context(found.get_string(1))
	var value_constructor := RegEx.new()
	value_constructor.compile('^([A-Za-z][A-Za-z0-9]*)\\.(?:new|fromRGB|fromHSV|fromHex|Angles|lookAt|fromMatrix|fromAxisAngle|fromOffset|fromScale)\\(')
	found = value_constructor.search(expression)
	if found: return _context(found.get_string(1))
	var parts := expression.split(".")
	var base: String = parts[0]
	var context: Dictionary
	match base:
		"script": context = _context("Instance", script_node if is_instance_valid(script_node) else null)
		"World", "workspace": context = _context("Workspace", scene_root if is_instance_valid(scene_root) else null)
		"game": context = _context("Game")
		"Enum": context = _context("Enum", null, true)
		_:
			if globals.has(base):
				context = _context(base, null, true)
			else:
				var declarations := RegEx.new()
				declarations.compile('(?m)\\blocal\\s+' + base + '(?:\\s*:\\s*[^=\\n]+)?\\s*=\\s*([^\\n]+)')
				var matches := declarations.search_all(source)
				if not matches.is_empty():
					var declaration: RegExMatch = matches[-1]
					context = resolve(declaration.get_string(1), source.left(declaration.get_start()), depth + 1)
				else: context = _context("Instance")
	parts.remove_at(0)
	return _chain(context, ".".join(parts))

func _method_return(context: Dictionary, method: String) -> Dictionary:
	var type_name: String = options_for(context).get(method, {}).get("type", "")
	return _context(type_name if not type_name.is_empty() else "Instance")

func _chain(context: Dictionary, tail: String) -> Dictionary:
	for key in tail.trim_prefix(".").split(".", false):
		var node: Node = context.node if is_instance_valid(context.node) else null
		if context.type == "Enum":
			context = _context("Enum." + key, null, true)
		elif context.type == "Game":
			context = _context("Workspace", scene_root) if key == "Workspace" else _context(key)
		elif key == "Parent":
			context = _context("Instance", node.get_parent() if node != null else null)
		elif node != null and node.has_node(NodePath(key)):
			context = _context("Instance", node.get_node(NodePath(key)))
		else:
			var options := options_for(context)
			context = _context(options.get(key, {}).get("type", "Instance"))
	return context

func _native_class(context: Dictionary) -> String:
	if is_instance_valid(context.node): return context.node.get_class()
	if context.type == "Workspace": return "Node"
	if classes.has(context.type): return classes[context.type].get("node", "Node")
	if services.has(context.type): return services[context.type].get("node", "Node")
	return GodotBridge.native_base(context.type.trim_prefix("Godot."), GodotBridge.project_node_classes())

func _reflected_script(type_name: String) -> Script:
	var path: String = classes.get(type_name, {}).get("script", "")
	if path.is_empty(): path = GodotBridge.project_node_classes().get(type_name, {}).get("path", "")
	return load(path) as Script if not path.is_empty() and ResourceLoader.exists(path, "Script") else null

func _reflect_methods(output: Dictionary, definitions: Array) -> void:
	for method in definitions:
		var name: String = method.name
		if name.begins_with("_") or output.has(name): continue
		var parameters := PackedStringArray()
		for argument in method.args: parameters.append(str(argument.name))
		if int(method.flags) & METHOD_FLAG_VARARG: parameters.append("...")
		var signature := "(" + ", ".join(parameters) + ")"
		output[name] = _entry(name, CodeEdit.KIND_FUNCTION, "", name + signature)
		var pascal := name.to_pascal_case()
		if not output.has(pascal): output[pascal] = _entry(pascal, CodeEdit.KIND_FUNCTION, "", pascal + signature)

func _property_type(key: String, spec: Dictionary, native: Dictionary) -> String:
	var kinds := {"parent": "Instance", "class": "string", "position": "Vector3", "transform": "CFrame", "size": "Vector3", "color": "Color3", "transparency": "number", "collision": "boolean", "value": "any"}
	if spec.kind == "native":
		var type_id: int = native.get(spec.property, {}).get("type", TYPE_NIL)
		return {TYPE_STRING: "string", TYPE_STRING_NAME: "string", TYPE_INT: "number", TYPE_FLOAT: "number", TYPE_BOOL: "boolean", TYPE_VECTOR3: "Vector3", TYPE_VECTOR2: "Vector2", TYPE_COLOR: "Color3", TYPE_TRANSFORM3D: "CFrame"}.get(type_id, "any")
	return kinds.get(spec.kind, "any")

func options_for(context: Dictionary) -> Dictionary:
	var output := {}
	var type_name: String = context.type
	if type_name == "Enum":
		for name in enums: output[name] = _entry(name, CodeEdit.KIND_ENUM, "Enum." + name)
		return output
	if type_name.begins_with("Enum."):
		for name in enums.get(type_name.trim_prefix("Enum."), {}): output[name] = _entry(name, CodeEdit.KIND_CONSTANT, "EnumItem")
		return output
	if type_name == "Game":
		for service in services: output[service] = _entry(service, CodeEdit.KIND_MEMBER, service)
		for service in ["Workspace", "RunService", "TweenService", "Debris", "InputService", "UserInputService", "HttpService", "DataStoreService", "CollectionService"]: output[service] = _entry(service, CodeEdit.KIND_MEMBER, service)
	for name in members.get(type_name, {}):
		var entry: Dictionary = members[type_name][name]
		if entry.static == context.static or type_name in ["Game", "Godot", "task"]: output[name] = entry
	var native_class := _native_class(context)
	if not native_class.is_empty() or type_name == "Instance":
		output.merge(members.get("Instance", {}), false)
		var native := {}
		if not native_class.is_empty():
			var property_list: Array = context.node.get_property_list() if is_instance_valid(context.node) else ClassDB.class_get_property_list(native_class)
			var method_list: Array = context.node.get_method_list() if is_instance_valid(context.node) else ClassDB.class_get_method_list(native_class)
			var signal_list: Array = context.node.get_signal_list() if is_instance_valid(context.node) else ClassDB.class_get_signal_list(native_class)
			var reflected: Script = context.node.get_script() if is_instance_valid(context.node) else _reflected_script(type_name)
			while reflected != null:
				property_list.append_array(reflected.get_script_property_list())
				method_list.append_array(reflected.get_script_method_list())
				signal_list.append_array(reflected.get_script_signal_list())
				reflected = reflected.get_base_script()
			for property in property_list:
				var name: String = property.name
				if name.begins_with("_") or name.contains("/") or int(property.usage) & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP): continue
				native[name] = property
				var kind := _property_type(name, {"kind": "native", "property": name}, native)
				output[name] = _entry(name, CodeEdit.KIND_MEMBER, kind)
				output[name.to_pascal_case()] = _entry(name.to_pascal_case(), CodeEdit.KIND_MEMBER, kind)
			_reflect_methods(output, method_list)
			for signal_info in signal_list:
				var name: String = signal_info.name
				if not name.begins_with("_") and not output.has(name): output[name] = _entry(name, CodeEdit.KIND_SIGNAL, "Signal")
		for key in properties:
			var spec: Dictionary = properties[key]
			var kind: String = spec.kind
			var applicable: bool = native_class.is_empty() or kind in ["parent", "class"] or key == "Name"
			if kind == "native": applicable = applicable or native.has(spec.property)
			if kind in ["position", "transform"]: applicable = applicable or ClassDB.is_parent_class(native_class, "Node3D") or ClassDB.is_parent_class(native_class, "Control") and kind == "position"
			if kind == "size": applicable = applicable or type_name == "Part" or ClassDB.is_parent_class(native_class, "Control")
			if kind in ["color", "transparency", "collision"]: applicable = applicable or type_name == "Part" or ClassDB.is_parent_class(native_class, "Light3D") and kind == "color"
			if kind == "value": applicable = applicable or classes.get(type_name, {}).has("value")
			if applicable:
				var type_value := _property_type(key, spec, native)
				if kind in ["position", "size"] and ClassDB.is_parent_class(native_class, "Control"): type_value = "Vector2"
				output[key] = _entry(key, CodeEdit.KIND_MEMBER, type_value)
		if type_name == "Part":
			output.Touched = _entry("Touched", CodeEdit.KIND_SIGNAL, "Signal")
			output.ApplyImpulse = _entry("ApplyImpulse", CodeEdit.KIND_FUNCTION, "", "ApplyImpulse(impulse)")
			output.ApplyImpulseAtPosition = _entry("ApplyImpulseAtPosition", CodeEdit.KIND_FUNCTION, "", "ApplyImpulseAtPosition(impulse, position)")
			output.ApplyAngularImpulse = _entry("ApplyAngularImpulse", CodeEdit.KIND_FUNCTION, "", "ApplyAngularImpulse(impulse)")
		if type_name == "ParticleEmitter":
			output.Emit = _entry("Emit", CodeEdit.KIND_FUNCTION, "", "Emit(count)")
			output.Clear = _entry("Clear", CodeEdit.KIND_FUNCTION, "", "Clear()")
		output.Archivable = _entry("Archivable", CodeEdit.KIND_MEMBER, "boolean")
		output.RodotLocked = _entry("RodotLocked", CodeEdit.KIND_MEMBER, "boolean")
		output.UniqueId = _entry("UniqueId", CodeEdit.KIND_MEMBER, "string")
		for key in classes.get(type_name, {}).get("members", {}):
			output[key] = _entry(key, CodeEdit.KIND_MEMBER, classes[type_name].members[key])
		var node: Node = context.node
		if is_instance_valid(node):
			for child in node.get_children(): output[str(child.name)] = _entry(str(child.name), CodeEdit.KIND_MEMBER, child.get_class())
	return output

func suggestions(before_caret: String) -> Dictionary:
	var string_context := RegEx.new()
	string_context.compile('(?:GetService|Instance\\.new)\\(["\']([^"\']*)$')
	var found := string_context.search(before_caret)
	if found:
		var output := {}
		var pool: Array = classes.keys() if found.get_string().begins_with("Instance") else services.keys() + ["Workspace", "RunService", "TweenService", "Debris", "InputService", "UserInputService", "HttpService", "DataStoreService", "CollectionService"]
		if found.get_string().begins_with("Instance"):
			pool.append_array(native_nodes)
			var registry := GodotBridge.project_node_classes()
			for name in registry:
				if not GodotBridge.native_base(name, registry).is_empty(): pool.append(name)
			if found.get_string(1).begins_with("Godot."):
				pool = native_nodes.map(func(name): return "Godot." + name)
		for name in pool: output[name] = _entry(name, CodeEdit.KIND_CONSTANT)
		return output
	var receiver := RegEx.new()
	receiver.compile('([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*)[.:][A-Za-z0-9_]*$')
	found = receiver.search(before_caret)
	if found: return options_for(resolve(found.get_string(1), before_caret))
	var output := globals.duplicate()
	var local_names := RegEx.new()
	local_names.compile('\\blocal\\s+(?:function\\s+)?([A-Za-z_][A-Za-z0-9_]*)')
	for item in local_names.search_all(before_caret): output[item.get_string(1)] = _entry(item.get_string(1), CodeEdit.KIND_VARIABLE)
	return output

func reference_entries() -> Dictionary:
	var output := {}
	for owner in members:
		for name in members[owner]:
			var entry: Dictionary = members[owner][name]
			output[owner + ("." if entry.static else ":") + name] = entry
	for name in properties: output["Instance." + name] = _entry(name, CodeEdit.KIND_MEMBER, _property_type(name, properties[name], {}))
	return output

func call_hint(before_caret: String) -> String:
	var regex := RegEx.new()
	regex.compile('([A-Za-z_][A-Za-z0-9_.]*)([.:])([A-Za-z_][A-Za-z0-9_]*)\\([^()]*$')
	var found := regex.search(before_caret)
	if found == null: return ""
	var options := options_for(resolve(found.get_string(1), before_caret))
	return options.get(found.get_string(3), {}).get("signature", "")
