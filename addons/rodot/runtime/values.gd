extends RefCounted

static func value(data: Variant) -> Dictionary:
	return {"handled": true, "value": data}

static func failure(message: String) -> Dictionary:
	return {"handled": true, "error": message}

static func is_number(data: Variant) -> bool:
	return (data is int or data is float) and is_finite(float(data))

static func compatible(previous: Variant, next: Variant) -> bool:
	return typeof(previous) == typeof(next) or (is_number(previous) and is_number(next))

static var _enums: Dictionary = {}

static func enums() -> Dictionary:
	if _enums.is_empty():
		_enums = JSON.parse_string(FileAccess.get_file_as_string("res://addons/rodot/api/enums.json"))
		for entries in _enums.values():
			for key in entries: entries[key] = int(entries[key])
	return _enums

static func enum_value(enum_name: String, number: int) -> Dictionary:
	return {"__type": "EnumItem", "EnumType": enum_name, "Name": enums()[enum_name].find_key(number)}
