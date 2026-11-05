@tool
extends RigidBody3D

enum PartShape { BALL, BLOCK, CYLINDER, WEDGE, CORNER_WEDGE }

const Adapter = preload("values.gd")

@export var archivable := true:
	set(value):
		archivable = value
		set_meta("rodot_archivable", value)

@export_group("Appearance")
@export var size := Vector3(4, 1, 2):
	set(value):
		size = value.max(Vector3.ONE * 0.01)
		_sync_geometry()
@export_enum("Ball", "Block", "Cylinder", "Wedge", "CornerWedge") var shape: int = PartShape.BLOCK:
	set(value):
		shape = clampi(value, 0, 4)
		_sync_geometry()
@export var color := Color(0.64, 0.64, 0.67):
	set(value):
		color = value
		_sync_appearance()
@export_range(0, 1, 0.01) var transparency := 0.0:
	set(value):
		transparency = clampf(value, 0, 1)
		_sync_appearance()
@export_range(0, 1, 0.01) var local_transparency_modifier := 0.0:
	set(value):
		local_transparency_modifier = clampf(value, 0, 1)
		_sync_appearance()
@export_range(0, 1, 0.01) var reflectance := 0.0:
	set(value):
		reflectance = clampf(value, 0, 1)
		_sync_appearance()
@export var cast_shadow := true:
	set(value):
		cast_shadow = value
		_sync_appearance()
@export_enum("Plastic:256", "SmoothPlastic:272", "Neon:288", "Wood:512", "WoodPlanks:528", "Marble:784", "Basalt:788", "Slate:800", "CrackedLava:804", "Concrete:816", "Limestone:820", "Granite:832", "Pavement:836", "Brick:848", "Pebble:864", "Cobblestone:880", "Rock:896", "Sandstone:912", "CorrodedMetal:1040", "DiamondPlate:1056", "Foil:1072", "Metal:1088", "Grass:1280", "LeafyGrass:1284", "Sand:1296", "Fabric:1312", "Snow:1328", "Mud:1344", "Ground:1360", "Asphalt:1376", "Salt:1392", "Ice:1536", "Glacier:1552", "Glass:1568", "ForceField:1584", "Air:1792", "Water:2048", "Cardboard:2304", "Carpet:2305", "CeramicTiles:2306", "ClayRoofTiles:2307", "RoofShingles:2308", "Leather:2309", "Plaster:2310", "Rubber:2311") var material: int = 256:
	set(value):
		material = value
		_sync_appearance()
@export var material_variant: BaseMaterial3D:
	set(value):
		material_variant = value
		_sync_appearance()

@export_group("Physics")
@export var anchored := false:
	set(value):
		anchored = value
		_sync_collision()
@export var can_collide := true:
	set(value):
		can_collide = value
		_sync_collision()
@export var can_touch := true:
	set(value):
		can_touch = value
		_sync_collision()
@export var can_query := true:
	set(value):
		can_query = value
		_sync_collision()
@export var collision_group := "Default":
	set(value):
		collision_group = value
		_sync_collision()
@export_range(0.001, 100, 0.001, "or_greater") var density := 0.7:
	set(value):
		density = maxf(0.001, value)
		_sync_mass()
@export var custom_physics: PhysicsMaterial:
	set(value):
		custom_physics = value
		_sync_mass()

@export var pivot_offset := Transform3D.IDENTITY
@export var locked := false:
	get:
		return bool(get_meta("_edit_lock_", false))
	set(value):
		locked = value
		if value: set_meta("_edit_lock_", true)
		elif has_meta("_edit_lock_"): remove_meta("_edit_lock_")

var _visual: MeshInstance3D
var _collider: CollisionShape3D
var _query_area: Area3D
var _query_shape: CollisionShape3D

func _enter_tree() -> void:
	set_meta("rodot_class", "Part")
	_visual = get_node_or_null("RodotMesh") as MeshInstance3D
	if _visual == null:
		_visual = MeshInstance3D.new()
		_visual.name = "RodotMesh"
		_visual.set_meta("rodot_internal", true)
		add_child(_visual, false, Node.INTERNAL_MODE_FRONT)
	_collider = get_node_or_null("RodotCollision") as CollisionShape3D
	if _collider == null:
		_collider = CollisionShape3D.new()
		_collider.name = "RodotCollision"
		_collider.set_meta("rodot_internal", true)
		add_child(_collider, false, Node.INTERNAL_MODE_FRONT)
	_sync_geometry()
	_sync_appearance()
	_sync_collision()

func _sync_geometry() -> void:
	if not is_inside_tree() or not is_instance_valid(_visual): return
	match shape:
		PartShape.BLOCK:
			var box := BoxMesh.new()
			box.size = size
			_visual.mesh = box
			var collision := BoxShape3D.new()
			collision.size = size
			_collider.shape = collision
		PartShape.BALL:
			_visual.mesh = _scaled_mesh(SphereMesh.new(), Basis.from_scale(size))
			_collider.shape = _visual.mesh.create_convex_shape()
		PartShape.CYLINDER:
			var basis := Basis.from_scale(size) * Basis(Vector3.BACK, PI / 2)
			_visual.mesh = _scaled_mesh(CylinderMesh.new(), basis)
			_collider.shape = _visual.mesh.create_convex_shape()
		_:
			_visual.mesh = _wedge_mesh(shape == PartShape.CORNER_WEDGE)
			_collider.shape = _visual.mesh.create_convex_shape()
	_sync_mass()
	if is_instance_valid(_query_shape): _query_shape.shape = _collider.shape

func _scaled_mesh(mesh: PrimitiveMesh, basis: Basis) -> ArrayMesh:
	if mesh is CylinderMesh:
		mesh.height = 1.0
	var builder := SurfaceTool.new()
	builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	builder.append_from(mesh, 0, Transform3D(basis, Vector3.ZERO))
	return builder.commit()

func _wedge_mesh(corner: bool) -> ArrayMesh:
	var points := [
		Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, -1, 1), Vector3(-1, -1, 1),
		Vector3(-1, 1, 1), Vector3(1, 1, 1)
	]
	var faces := [[0, 1, 2], [0, 2, 3], [0, 3, 4], [2, 4, 3], [0, 4, 1], [1, 4, 2]]
	if not corner:
		faces = [[0, 1, 2], [0, 2, 3], [0, 3, 4], [1, 5, 2], [2, 4, 3], [2, 5, 4], [0, 4, 5], [0, 5, 1]]
	var builder := SurfaceTool.new()
	builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	builder.set_smooth_group(-1)
	var center := Vector3(-0.25, -0.5, 0.25)
	for face in faces:
		var a: Vector3 = points[face[0]]
		var b: Vector3 = points[face[1]]
		var c: Vector3 = points[face[2]]
		if (b - a).cross(c - a).dot(center - a) < 0:
			var swap := b
			b = c
			c = swap
		for point in [a, b, c]: builder.add_vertex(point * size * 0.5)
	builder.generate_normals()
	return builder.commit()

func _sync_appearance() -> void:
	if not is_inside_tree() or not is_instance_valid(_visual): return
	_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tint := Color(color.r, color.g, color.b, (1.0 - transparency) * (1.0 - local_transparency_modifier))
	if material_variant != null:
		var variant := material_variant.duplicate() as BaseMaterial3D
		variant.albedo_color *= tint
		if variant.albedo_color.a < 1.0: variant.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_visual.material_override = variant
		return
	var surface := StandardMaterial3D.new()
	surface.albedo_color = tint
	surface.roughness = 1.0 - reflectance * 0.85
	match material:
		272, 1536, 1552, 1568, 2306:
			surface.roughness = minf(surface.roughness, 0.22)
		288:
			surface.emission_enabled = true
			surface.emission = color
			surface.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		1040, 1056, 1072, 1088:
			surface.metallic = 0.9
			surface.roughness = minf(surface.roughness, 0.35)
	if surface.albedo_color.a < 1.0:
		surface.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_visual.material_override = surface

func _sync_collision() -> void:
	freeze = anchored
	var groups: Dictionary = ProjectSettings.get_setting("rodot/physics/collision_groups", {})
	var group: Dictionary = groups.get(collision_group, {"layer": 1, "mask": 1})
	collision_layer = int(group.get("layer", 1)) if can_collide else 0
	collision_mask = int(group.get("mask", 1)) if can_collide else 0
	input_ray_pickable = can_query
	set_meta("rodot_can_query", can_query)
	_sync_query_proxy(int(group.get("layer", 1)))
	max_contacts_reported = 8
	if contact_monitor != can_touch: contact_monitor = can_touch

func _sync_query_proxy(layer: int) -> void:
	if not is_inside_tree() or not is_instance_valid(_collider): return
	var needs_proxy := can_query and not can_collide
	if not needs_proxy and not is_instance_valid(_query_area): return
	if not is_instance_valid(_query_area):
		_query_area = get_node_or_null("RodotQuery") as Area3D
		if _query_area == null:
			_query_area = Area3D.new()
			_query_area.name = "RodotQuery"
			_query_area.monitoring = false
			_query_area.monitorable = false
			_query_area.input_ray_pickable = false
			_query_area.collision_mask = 0
			_query_area.set_meta("rodot_query_proxy", true)
			_query_area.set_meta("rodot_internal", true)
			add_child(_query_area, false, Node.INTERNAL_MODE_FRONT)
		_query_shape = _query_area.get_node_or_null("Shape") as CollisionShape3D
		if _query_shape == null:
			_query_shape = CollisionShape3D.new()
			_query_shape.name = "Shape"
			_query_area.add_child(_query_shape, false, Node.INTERNAL_MODE_FRONT)
	_query_shape.shape = _collider.shape
	_query_area.collision_layer = layer if needs_proxy else 0

func _sync_mass() -> void:
	physics_material_override = custom_physics
	var factor := {PartShape.BALL: PI / 6, PartShape.CYLINDER: PI / 4, PartShape.WEDGE: 0.5, PartShape.CORNER_WEDGE: 1.0 / 3.0}.get(shape, 1.0) as float
	mass = maxf(0.001, size.x * size.y * size.z * density * factor)
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	match shape:
		PartShape.WEDGE: center_of_mass = size * Vector3(0, -1.0 / 6.0, 1.0 / 6.0)
		PartShape.CORNER_WEDGE: center_of_mass = size * Vector3(-0.125, -0.25, 0.125)
		_: center_of_mass = Vector3.ZERO

func _physical_properties() -> Dictionary:
	var friction_value := custom_physics.friction if custom_physics else 1.0
	var bounce_value := custom_physics.bounce if custom_physics else 0.0
	return {"__type": "PhysicalProperties", "Density": density, "Friction": friction_value, "Elasticity": bounce_value, "FrictionWeight": 1, "ElasticityWeight": 1}

func _rodot_get(key: String) -> Dictionary:
	match key:
		"Shape": return Adapter.value(Adapter.enum_value("PartType", shape))
		"Material": return Adapter.value(Adapter.enum_value("Material", material))
		"AssemblyMass": return Adapter.value(INF if anchored else mass)
		"AssemblyRootPart": return Adapter.value(self)
		"AssemblyCenterOfMass": return Adapter.value(to_global(center_of_mass) if is_inside_tree() else transform * center_of_mass)
		"CenterOfMass": return Adapter.value(center_of_mass)
		"ExtentsSize": return Adapter.value(size)
		"ExtentsCFrame", "Origin": return Adapter.value(global_transform if is_inside_tree() else transform)
		"Mass": return Adapter.value(mass)
		"CurrentPhysicalProperties": return Adapter.value(_physical_properties())
		"CustomPhysicalProperties": return Adapter.value(_physical_properties() if custom_physics != null else null)
		"MaterialVariant": return Adapter.value(material_variant.resource_path if material_variant != null else "")
		"Rotation": return Adapter.value(rotation_degrees)
		"Velocity": return Adapter.value(linear_velocity)
		"RotVelocity": return Adapter.value(angular_velocity)
		"Size", "Color", "Transparency", "Anchored", "CanCollide": return Adapter.value(get(key.to_snake_case()))
	return {}

func _rodot_set(key: String, value: Variant) -> Dictionary:
	match key:
		"AssemblyMass", "AssemblyRootPart", "AssemblyCenterOfMass", "CenterOfMass", "ExtentsSize", "ExtentsCFrame", "Origin", "Mass", "CurrentPhysicalProperties":
			return Adapter.failure(key + " is read-only")
		"Shape", "Material":
			var enum_name := "PartType" if key == "Shape" else "Material"
			if not Adapter.is_number(value) or not Adapter.enums()[enum_name].values().has(int(value)) or float(value) != int(value):
				return Adapter.failure("Expected Enum." + enum_name)
			set(key.to_snake_case(), int(value))
		"CustomPhysicalProperties":
			if value == null:
				custom_physics = null
				density = 0.7
			elif value is Dictionary and value.get("__type", "") == "PhysicalProperties":
				var physics := PhysicsMaterial.new()
				physics.friction = clampf(value.Friction, 0, 1)
				physics.bounce = clampf(value.Elasticity, 0, 1)
				custom_physics = physics
				density = value.Density
			else:
				return Adapter.failure("Expected PhysicalProperties or nil")
		"MaterialVariant":
			if not value is String: return Adapter.failure("Expected a project material path")
			if value.is_empty(): material_variant = null
			else:
				var resource := load(value) as BaseMaterial3D if ResourceLoader.exists(value, "Material") else null
				if resource == null: return Adapter.failure("Standard or ORM material resource not found: " + value)
				material_variant = resource
		"Size", "Color", "Transparency", "Anchored", "CanCollide", "Rotation", "Velocity", "RotVelocity":
			var native: String = {"Rotation": "rotation_degrees", "Velocity": "linear_velocity", "RotVelocity": "angular_velocity"}.get(key, key.to_snake_case())
			if not Adapter.compatible(get(native), value): return Adapter.failure("Wrong type for " + key)
			if key == "Size" and (value.x <= 0 or value.y <= 0 or value.z <= 0): return Adapter.failure("Size must be positive")
			set(native, value)
		_:
			return {}
	return {"handled": true}

func apply_impulse_at_position(impulse: Vector3, world_position: Vector3) -> void:
	apply_impulse(impulse, world_position - global_position)

func get_mass_value() -> float:
	return mass

func get_pivot() -> Transform3D:
	return (global_transform if is_inside_tree() else transform) * pivot_offset

func pivot_to(target: Transform3D) -> void:
	var origin := target * pivot_offset.affine_inverse()
	if is_inside_tree(): global_transform = origin
	else: transform = origin
