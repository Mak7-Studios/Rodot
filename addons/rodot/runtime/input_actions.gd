extends RefCounted

static func query(operation: String, args: Array) -> Variant:
	if operation == "actions": return Array(InputMap.get_actions())
	if operation == "has": return not args.is_empty() and args[0] is String and InputMap.has_action(args[0])
	var count := 1
	if operation == "axis": count = 2
	elif operation == "vector": count = 4
	if args.size() < count: return {"__error": "Missing Input Map action name"}
	for i in range(count):
		if not args[i] is String or not InputMap.has_action(args[i]):
			return {"__error": "Unknown Input Map action: " + str(args[i])}
	match operation:
		"pressed": return Input.is_action_pressed(args[0])
		"just_pressed": return Input.is_action_just_pressed(args[0])
		"just_released": return Input.is_action_just_released(args[0])
		"strength": return Input.get_action_strength(args[0])
		"axis": return Input.get_axis(args[0], args[1])
		"vector":
			var deadzone = args[4] if args.size() > 4 else -1.0
			if not (deadzone is int or deadzone is float) or not is_finite(deadzone) or (deadzone != -1.0 and (deadzone < 0.0 or deadzone > 1.0)):
				return {"__error": "Input deadzone must be between 0 and 1, or -1 to use the Input Map"}
			return Input.get_vector(args[0], args[1], args[2], args[3], deadzone)
	return {"__error": "Unknown InputService operation: " + operation}

static func collect_events(events: Array) -> void:
	for action in InputMap.get_actions():
		if Input.is_action_just_pressed(action): events.append([0, "input:action_pressed", [str(action)]])
		if Input.is_action_just_released(action): events.append([0, "input:action_released", [str(action)]])
