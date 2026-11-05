@tool
extends EditorInspectorPlugin

const Attributes = preload("../runtime/attributes.gd")

class AttributeView extends RefCounted:
	var target: WeakRef
	var attributes: Dictionary:
		get:
			var node: Node = target.get_ref()
			return Attributes.all(node) if is_instance_valid(node) else {}

var undo: EditorUndoRedoManager

func _can_handle(object: Object) -> bool:
	var scene := EditorInterface.get_edited_scene_root()
	return object is Node and scene != null and (object == scene or scene.is_ancestor_of(object))

func _parse_property(_object: Object, _type: Variant.Type, name: String, _hint: PropertyHint, _hint_text: String, _usage: int, _wide: bool) -> bool:
	return name.begins_with("metadata/" + Attributes.PREFIX)

func _parse_end(object: Object) -> void:
	var view := AttributeView.new()
	view.target = weakref(object)
	var editor := EditorInspector.instantiate_property_editor(view, TYPE_DICTIONARY, "attributes", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR)
	if editor == null: return
	editor.set_object_and_property(view, &"attributes")
	editor.label = "Attributes"
	editor.tooltip_text = "Values available through Luau GetAttribute and SetAttribute."
	editor.property_changed.connect(_change.bind(view, editor))
	var panel := VBoxContainer.new()
	panel.add_child(editor)
	add_custom_control(panel)
	editor.update_property.call_deferred()

func _change(_property: StringName, value: Variant, _field: StringName, changing: bool, view: AttributeView, editor: EditorProperty) -> void:
	var node: Node = view.target.get_ref()
	if not is_instance_valid(node) or not value is Dictionary: return
	for key in value:
		if not Attributes.valid_name(key):
			if not changing: push_warning("Rodot attribute names use letters, digits, and underscores.")
			editor.update_property.call_deferred()
			return
	var before := Attributes.all(node)
	if before == value: return
	undo.create_action("Edit Rodot Attributes", UndoRedo.MERGE_ENDS if changing else UndoRedo.MERGE_DISABLE, node)
	var names := before.keys()
	for key in value:
		if not names.has(key): names.append(key)
	for key in names:
		if before.get(key) == value.get(key): continue
		var meta := Attributes.PREFIX + str(key)
		undo.add_do_method(node, "set_meta", meta, value.get(key))
		undo.add_undo_method(node, "set_meta", meta, before.get(key))
	undo.commit_action()
	if is_instance_valid(editor) and not changing: editor.update_property.call_deferred()
