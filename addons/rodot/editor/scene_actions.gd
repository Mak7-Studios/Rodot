@tool
extends RefCounted

var plugin: EditorPlugin
var trees: Array[Tree] = []

func install(editor_plugin: EditorPlugin) -> void:
	plugin = editor_plugin
	for candidate in plugin.get_editor_interface().get_base_control().find_children("*", "Tree", true, false):
		var ancestor: Node = candidate.get_parent()
		var scene_editor := false
		var scene_dock := false
		while ancestor != null:
			scene_editor = scene_editor or ancestor.is_class("SceneTreeEditor")
			scene_dock = scene_dock or ancestor.is_class("SceneTreeDock")
			ancestor = ancestor.get_parent()
		if scene_editor and scene_dock:
			trees.append(candidate)
			candidate.gui_input.connect(_input.bind(candidate))
			candidate.item_activated.connect(_activated.bind(candidate))

func _script_node(tree: Tree, item: TreeItem) -> Node:
	if item == null: return null
	var path = item.get_metadata(0)
	if not path is NodePath and not path is String: return null
	var node := tree.get_node_or_null(NodePath(path))
	var root := plugin.get_editor_interface().get_edited_scene_root()
	if node == null or root == null or node != root and not root.is_ancestor_of(node): return null
	return node if node.has_method("is_module_script") else null

func _input(event: InputEvent, tree: Tree) -> void:
	if not event is InputEventMouseButton or not event.pressed or not event.double_click or event.button_index != MOUSE_BUTTON_LEFT: return
	var node := _script_node(tree, tree.get_item_at_position(event.position))
	if node != null:
		tree.accept_event()
		plugin.call_deferred("_open_scene_script", node.get_instance_id())

func _activated(tree: Tree) -> void:
	var node := _script_node(tree, tree.get_selected())
	if node != null: plugin.call_deferred("_open_scene_script", node.get_instance_id())

func uninstall() -> void:
	for tree in trees:
		if not is_instance_valid(tree): continue
		if tree.gui_input.is_connected(_input.bind(tree)): tree.gui_input.disconnect(_input.bind(tree))
		if tree.item_activated.is_connected(_activated.bind(tree)): tree.item_activated.disconnect(_activated.bind(tree))
	trees.clear()
