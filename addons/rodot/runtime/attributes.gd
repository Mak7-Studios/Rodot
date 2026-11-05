@tool
extends RefCounted

const PREFIX := "rodot_attr_"

static func all(node: Node) -> Dictionary:
	var result := {}
	for key in node.get_meta_list():
		if str(key).begins_with(PREFIX): result[str(key).trim_prefix(PREFIX)] = node.get_meta(key)
	return result

static func valid_name(value: Variant) -> bool:
	return value is String and not value.is_empty() and (PREFIX + value).is_valid_ascii_identifier()
