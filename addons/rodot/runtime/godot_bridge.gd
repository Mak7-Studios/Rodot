@tool
extends RefCounted

static func member_name(object: Object, name: String, signal_member := false) -> String:
	if name.begins_with("_"): return ""
	for candidate in [name, name.to_snake_case()]:
		if signal_member and object.has_signal(candidate): return candidate
		if not signal_member and object.has_method(candidate): return candidate
	return ""

static func property_info(object: Object, names: Array) -> Dictionary:
	for name in names:
		if name.is_empty() or name.begins_with("_"): continue
		for property in object.get_property_list():
			if property.name == name and not int(property.usage) & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP): return property
	return {}

static func project_node_classes() -> Dictionary:
	var result := {}
	for entry in ProjectSettings.get_global_class_list():
		if entry.language == "GDScript": result[entry.class] = entry
	return result

static func native_base(class_name_value: String, registry: Dictionary) -> String:
	var seen := {}
	while registry.has(class_name_value) and not seen.has(class_name_value):
		seen[class_name_value] = true
		class_name_value = registry[class_name_value].base
	if ClassDB.class_exists(class_name_value) and ClassDB.is_parent_class(class_name_value, "Node"): return class_name_value
	return ""

static func invoke(object: Object, method: String, arguments: Array) -> Variant:
	for info in object.get_method_list():
		if info.name != method: continue
		var parameters: Array = info.args
		var minimum: int = parameters.size() - info.default_args.size()
		if arguments.size() < minimum or (arguments.size() > parameters.size() and not int(info.flags) & METHOD_FLAG_VARARG):
			return {"__error": "Wrong number of arguments for " + method}
		for i in range(mini(arguments.size(), parameters.size())):
			var type: int = parameters[i].type
			if type == TYPE_NIL: continue
			var value = arguments[i]
			if not _compatible(type, value): return {"__error": "Wrong type for %s argument %s" % [method, parameters[i].name]}
			arguments[i] = _convert(type, value)
		return object.callv(method, arguments)
	return {"__error": "Unknown Godot method: " + method}

static func _compatible(type: int, value: Variant) -> bool:
	if type == TYPE_NIL or typeof(value) == type: return true
	if type == TYPE_OBJECT: return value == null or value is Object
	if type in [TYPE_INT, TYPE_FLOAT]: return value is int or value is float
	if type in [TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH]: return value is String or value is StringName or value is NodePath
	return false

static func _convert(type: int, value: Variant) -> Variant:
	if typeof(value) == type or type in [TYPE_NIL, TYPE_OBJECT]: return value
	return type_convert(value, type)

static func set_property(object: Object, info: Dictionary, value: Variant) -> Variant:
	if int(info.usage) & PROPERTY_USAGE_READ_ONLY: return {"__error": str(info.name) + " is read-only"}
	if not _compatible(info.type, value): return {"__error": "Wrong type for " + str(info.name)}
	object.set(info.name, _convert(info.type, value))
	return null

static func project_path(input: Variant) -> String:
	if not (input is String or input is NodePath): return ""
	var path := str(input).replace("\\", "/")
	if path.begins_with("res://"):
		path = path.trim_prefix("res://")
	elif path.is_absolute_path() or path.contains("://"):
		return ""
	path = path.simplify_path()
	if path.is_empty() or path == "." or path == ".." or path.begins_with("../") or path.is_absolute_path(): return ""
	return "res://" + path

static func _inline_source(body: String) -> String:
	var lines := body.replace("\r\n", "\n").split("\n")
	var common_indent := -1
	for i in range(lines.size()):
		var line := lines[i]
		if line.strip_edges().is_empty(): continue
		var body_text := line.strip_edges(true, false)
		var leading := line.left(line.length() - body_text.length()).replace("\t", "    ")
		lines[i] = leading + body_text
		var indent := leading.length()
		common_indent = indent if common_indent < 0 else mini(common_indent, indent)
	if common_indent < 0: return ""
	var code := "extends RefCounted\nvar workspace: Node\nvar script_node: Node\nvar args: Array\nfunc run():\n"
	for line in lines:
		if line.strip_edges().is_empty(): code += "\n"
		else: code += "    " + line.substr(common_indent) + "\n"
	return code

static func run_gdscript(input: Variant, scene: Node, runner: Node, arguments: Array) -> Variant:
	if Engine.is_editor_hint(): return {"__error": "Godot:Run is available while the project is running."}
	var script_resource: GDScript
	var from_path := input is NodePath
	if from_path:
		var path := project_path(input)
		if not path.ends_with(".gd") or not ResourceLoader.exists(path, "GDScript"):
			return {"__error": "Expected Path.new with a project .gd file"}
		script_resource = load(path) as GDScript
	elif input is String:
		var source := _inline_source(input)
		if source.is_empty(): return null
		script_resource = GDScript.new()
		script_resource.source_code = source
		if script_resource.reload() != OK: return {"__error": "Could not compile the inline GDScript. See Godot's debugger."}
	else:
		return {"__error": "Godot:Run expects GDScript text or a Path"}
	if script_resource == null or not script_resource.can_instantiate() or not ClassDB.is_parent_class(script_resource.get_instance_base_type(), "RefCounted"):
		return {"__error": "Godot:Run expects a RefCounted GDScript with func run()"}
	var found_run := false
	for method in script_resource.get_script_method_list():
		if method.name == "run": found_run = true
		if method.name == "_init" and method.args.size() > method.default_args.size():
			return {"__error": "Godot:Run expects a script that can be constructed without arguments"}
	if not found_run: return {"__error": "The GDScript needs a func run() entry point"}
	var program: RefCounted = script_resource.new()
	if not from_path:
		program.workspace = scene
		program.script_node = runner
		program.args = arguments
		arguments = []
	return invoke(program, "run", arguments)
