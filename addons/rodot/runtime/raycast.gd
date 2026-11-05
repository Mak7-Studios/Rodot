extends RefCounted

const Values = preload("values.gd")

static func cast(scene: Node, origin: Variant, direction: Variant, params: Variant) -> Variant:
	if not origin is Vector3 or not direction is Vector3 or not origin.is_finite() or not direction.is_finite():
		return {"__error": "Raycast expects finite Vector3 origin and direction"}
	if direction.is_zero_approx() or scene == null or not scene.is_inside_tree(): return null
	if params == null: params = {}
	if not params is Dictionary: return {"__error": "Raycast expects RaycastParams"}
	var include = params.get("IncludeInstances")
	var exclude = params.get("ExcludeInstances", [])
	var filter = params.get("FilterDescendantsInstances", [])
	if not exclude is Array or not filter is Array or (include != null and not include is Array):
		return {"__error": "Raycast filters must be arrays of Instances"}
	var use_include := int(params.get("FilterType", 0)) == 1
	var respect_collision := bool(params.get("RespectCanCollide", false))
	var include_areas := bool(params.get("IncludeAreas", false))
	var groups: Dictionary = ProjectSettings.get_setting("rodot/physics/collision_groups", {})
	var group: Dictionary = groups.get(str(params.get("CollisionGroup", "Default")), {})
	var mask := int(params.get("CollisionMask", group.get("mask", 0xFFFFFFFF)))
	var world: World3D = scene.get_world_3d() if scene is Node3D else scene.get_viewport().find_world_3d()
	if world == null: return null
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null: return {"__error": "Physics space is busy. Raycast from Godot.PhysicsProcess."}
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction, mask)
	query.collide_with_areas = include_areas or not respect_collision
	var skipped: Array[RID] = []
	while true:
		var hit := space.intersect_ray(query)
		if hit.is_empty(): return null
		var collider: Node = hit.get("collider") as Node
		var proxy: bool = collider != null and collider.get_meta("rodot_query_proxy", false) == true
		var target := collider.get_parent() if proxy else collider
		var allowed := target != null and (target == scene or scene.is_ancestor_of(target))
		allowed = allowed and target.get_meta("rodot_can_query", true) == true
		allowed = allowed and (not collider is Area3D or include_areas or proxy) and (not proxy or not respect_collision)
		if allowed:
			allowed = not _in_filter(target, exclude) and (include == null or _in_filter(target, include))
			allowed = allowed and (_in_filter(target, filter) == use_include)
		if allowed:
			var material := Values.enum_value("Material", 256)
			if target.get_meta("rodot_class", "") == "Part" and target.has_method("_rodot_get"):
				material = target._rodot_get("Material").get("value", material)
			return {"__type": "RaycastResult", "Instance": target, "Position": hit.position, "Normal": hit.normal, "Distance": origin.distance_to(hit.position), "Material": material}
		var rid: RID = hit.rid
		if skipped.has(rid): return null
		skipped.append(rid)
		query.exclude = skipped
	return null

static func _in_filter(node: Node, entries: Array) -> bool:
	for entry in entries:
		if is_instance_valid(entry) and entry is Node and (entry == node or entry.is_ancestor_of(node)): return true
	return false
