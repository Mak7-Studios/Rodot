@tool
extends EditorPlugin

const Content = preload("../runtime/content.gd")

var dock: VBoxContainer
var workspace: Control
var picker: EditorFileDialog
var source_exporter: EditorExportPlugin
var file_menu: EditorContextMenuPlugin
var edit_button: Button
var runtime_label: Label
var picker_mode := "open"
var script_editor: ScriptEditor
var native_controls: Dictionary = {}
var luau_visible := false
var last_edited_node := 0
var last_node_source := ""
var scene_actions: RefCounted
var pending_script_id := 0
var rodot_icon: Texture2D
var attributes_inspector: EditorInspectorPlugin
var runtime_debugger: EditorDebuggerPlugin
var supabase_setup: RefCounted

func _enter_tree() -> void:
    _register_datastore_settings()
    supabase_setup = preload("supabase_setup.gd").new()
    supabase_setup.install(self)
    var online_assets: String = Content.ONLINE_SETTING
    if not ProjectSettings.has_setting(online_assets): ProjectSettings.set_setting(online_assets, false)
    ProjectSettings.set_initial_value(online_assets, false)
    ProjectSettings.add_property_info({"name": online_assets, "type": TYPE_BOOL})
    ProjectSettings.set_as_basic(online_assets, true)
    rodot_icon = _load_icon("RodotIcon.png", 32)
    attributes_inspector = preload("attributes_inspector.gd").new()
    attributes_inspector.undo = get_undo_redo()
    add_inspector_plugin(attributes_inspector)
    runtime_debugger = preload("runtime_debugger.gd").new()
    runtime_debugger.jump_requested.connect(_open_runtime_error)
    add_debugger_plugin(runtime_debugger)
    source_exporter = preload("export.gd").new()
    add_export_plugin(source_exporter)
    add_custom_type("RodotScript", "Node", preload("../runtime/script.gd"), _load_class_icon("Script"))
    add_custom_type("Part", "RigidBody3D", preload("../runtime/part.gd"), _load_class_icon("Part"))
    add_custom_type("RodotInstance", "Node", preload("../runtime/instance.gd"), rodot_icon)
    add_custom_type("RodotModuleScript", "Node", preload("../runtime/module_script.gd"), _load_class_icon("ModuleScript"))
    add_custom_type("ParticleEmitter", "Node3D", preload("../runtime/particle_emitter.gd"), _load_class_icon("ParticleEmitter"))
    add_custom_type("RodotDecal", "Node3D", preload("../runtime/decal.gd"), _load_class_icon("Decal"))
    add_custom_type("Attachment", "Node3D", preload("../runtime/attachment.gd"), _load_class_icon("Attachment"))
    add_custom_type("Beam", "MeshInstance3D", preload("../runtime/beam.gd"), _load_class_icon("Beam"))
    add_custom_type("Trail", "MeshInstance3D", preload("../runtime/trail.gd"), _load_class_icon("Trail"))
    add_custom_type("Sound", "Node3D", preload("../runtime/sound.gd"), _load_class_icon("Sound"))
    if not ProjectSettings.has_setting("autoload/Rodot"):
        add_autoload_singleton("Rodot", "res://addons/rodot/runtime/runtime.gd")
        ProjectSettings.save()
    workspace = preload("workspace.gd").new()
    workspace.editor_font = get_editor_interface().get_base_control().get_theme_font("source", "EditorFonts")
    var settings := get_editor_interface().get_editor_settings()
    if settings.has_setting("interface/editor/code_font_size"):
        workspace.editor_font_size = settings.get_setting("interface/editor/code_font_size")
    script_editor = get_editor_interface().get_script_editor()
    script_editor.add_child(workspace)
    workspace.hide()
    workspace.native_scripts_requested.connect(_show_native)
    script_editor.editor_script_changed.connect(func(_script): _show_native())
    get_editor_interface().get_inspector().edited_object_changed.connect(func():
        if get_editor_interface().get_inspector().get_edited_object() is Script: _show_native()
    )
    workspace.file_action_requested.connect(_file_action)
    workspace.current_script_changed.connect(func(_path): _refresh_scene_ui())
    picker = EditorFileDialog.new()
    picker.access = EditorFileDialog.ACCESS_RESOURCES
    picker.filters = PackedStringArray(["*.luau ; Luau scripts"])
    picker.file_selected.connect(func(path):
        picker.hide()
        if picker_mode == "save": workspace.save_to_path(path)
        elif picker_mode == "create":
            if workspace.save_to_path(path): _assign_script_source(path)
        else: _open_path(path)
        get_editor_interface().get_resource_filesystem().scan()
    )
    workspace.add_child(picker)
    picker.canceled.connect(func(): pending_script_id = 0)
    _build_dock()
    file_menu = preload("file_menu.gd").new()
    file_menu.open_script = _open_path
    add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, file_menu)
    get_editor_interface().get_selection().selection_changed.connect(func():
        var selected := _selected_node()
        if selected == null or selected.get_instance_id() != last_edited_node:
            last_edited_node = 0
            last_node_source = ""
        _refresh_scene_ui()
    )
    get_editor_interface().get_resource_filesystem().filesystem_changed.connect(workspace.refresh_files)
    scene_changed.connect(func(_root): _refresh_scene_ui())
    _refresh_scene_ui()
    call_deferred("_install_scene_actions")

func _register_datastore_settings() -> void:
    const Config = preload("../runtime/data_store_http.gd")
    for name in [Config.DEFAULT, Config.NAMESPACE, Config.MANUAL, Config.SUPABASE]:
        var is_backend: bool = name == Config.DEFAULT
        var initial: Variant = 0 if is_backend else ""
        if not ProjectSettings.has_setting(name): ProjectSettings.set_setting(name, initial)
        ProjectSettings.set_initial_value(name, initial)
        var info := {"name": name, "type": TYPE_INT if is_backend else TYPE_STRING}
        if is_backend:
            info.hint = PROPERTY_HINT_ENUM
            info.hint_string = "Local,Manual,Supabase"
        ProjectSettings.add_property_info(info)
        ProjectSettings.set_as_basic(name, true)

func _load_icon(filename: String, size: int = 0) -> Texture2D:
    var icon_image := Image.new()
    icon_image.load_png_from_buffer(FileAccess.get_file_as_bytes("res://addons/rodot/branding/".path_join(filename)))
    if size > 0: icon_image.resize(size, size, Image.INTERPOLATE_LANCZOS)
    return ImageTexture.create_from_image(icon_image)

func _load_class_icon(class_name_in_content: String) -> Texture2D:
    var editor := get_editor_interface().get_base_control()
    var text_color := editor.get_theme_color("font_color", "Label")
    var theme_variant := "Dark" if text_color.get_luminance() > 0.5 else "Light"
    var icon_path := Content.ROOT + "studio_svg_textures/Shared/InsertableObjects/%s/Standard/%s.png" % [theme_variant, class_name_in_content]
    var icon := Content.texture(icon_path)
    return icon if icon != null else rodot_icon

func _has_main_screen() -> bool:
    return false

func _get_plugin_name() -> String:
    return "Rodot"

func _get_plugin_icon() -> Texture2D:
    return rodot_icon

func _show_luau() -> void:
    get_editor_interface().set_main_screen_editor("Script")
    if not luau_visible:
        native_controls.clear()
        for child in script_editor.get_children():
            if child is Control and child != workspace and not child is Window:
                native_controls[child] = child.visible
                child.hide()
    luau_visible = true
    workspace.show()
    _refresh_scene_ui()

func _show_native() -> void:
    if not is_instance_valid(workspace): return
    workspace.hide()
    for control in native_controls:
        if is_instance_valid(control): control.visible = native_controls[control]
    native_controls.clear()
    luau_visible = false

func _handles(object: Object) -> bool:
    if object is Node and object.has_method("is_module_script"): return true
    return object is Resource and object.resource_path.ends_with(".luau")

func _edit(object: Object) -> void:
    if workspace == null or object == null: return
    if object is Node and object.has_method("is_module_script"):
        if object.get_instance_id() != last_edited_node or object.source != last_node_source:
            last_edited_node = object.get_instance_id()
            last_node_source = object.source
            if luau_visible and not object.source.is_empty(): workspace.open_path(object.source)
    elif object is Resource and object.resource_path.ends_with(".luau"):
        _open_path(object.resource_path)
    _refresh_scene_ui()

func _get_unsaved_status(_for_scene: String) -> String:
    return workspace.unsaved_status() if is_instance_valid(workspace) else ""

func _save_external_data() -> void:
    if is_instance_valid(workspace):
        workspace.save_all()
        workspace._save_session()

func _apply_changes() -> void:
    if is_instance_valid(workspace): workspace.save_all()

func _open_runtime_error(path: String, line: int) -> void:
    if not path.begins_with("res://") or not path.ends_with(".luau") or not FileAccess.file_exists(path): return
    _open_path(path)
    var code: CodeEdit = workspace.current_editor()
    if code == null or workspace.current_path() != path: return
    code.set_caret_line(clampi(line - 1, 0, code.get_line_count() - 1))
    code.set_caret_column(0)
    code.center_viewport_to_caret()
    code.grab_focus()

func _open_path(path: String) -> void:
    workspace.open_path(path)
    _show_luau()
    _refresh_scene_ui()

func _file_action(mode: String) -> void:
    picker_mode = mode
    picker.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE if mode == "save" else EditorFileDialog.FILE_MODE_OPEN_FILE
    if mode == "save": picker.current_file = "new_script.luau" if workspace.current_path().is_empty() else workspace.current_path().get_file()
    picker.popup_centered_ratio(0.65)

func _install_scene_actions() -> void:
    scene_actions = preload("scene_actions.gd").new()
    scene_actions.install(self)

func _open_scene_script(id: int) -> void:
    if pending_script_id == id and picker.visible: return
    var node = instance_from_id(id)
    if not is_instance_valid(node) or not node is Node or not node.has_method("is_module_script"): return
    if not node.source.is_empty():
        _open_path(node.source)
        return
    pending_script_id = id
    _show_luau()
    workspace.new_script(node.is_module_script())
    workspace.pending_key = workspace.current_key
    picker_mode = "create"
    picker.title = "New script"
    picker.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
    DirAccess.make_dir_recursive_absolute("res://scripts")
    var basename: String = str(node.name).validate_filename()
    var filename := basename + ".luau"
    var suffix := 2
    while FileAccess.file_exists("res://scripts/" + filename):
        filename = basename + str(suffix) + ".luau"
        suffix += 1
    picker.current_dir = "res://scripts"
    picker.current_file = filename
    picker.popup_centered_ratio(0.65)

func _assign_script_source(path: String) -> void:
    var node = instance_from_id(pending_script_id)
    pending_script_id = 0
    if not is_instance_valid(node) or not node is Node or not node.has_method("is_module_script"): return
    var root := get_editor_interface().get_edited_scene_root()
    if root == null or node != root and not root.is_ancestor_of(node): return
    var undo := get_undo_redo()
    undo.create_action("Set script source")
    undo.add_do_property(node, "source", path)
    undo.add_undo_property(node, "source", node.source)
    undo.commit_action()
    _open_path(path)

func _camera() -> Camera3D:
    var camera := Camera3D.new()
    camera.name = "Camera"
    var position_value := Vector3(10, 8, 12)
    camera.transform = Transform3D(Basis.looking_at(-position_value, Vector3.UP), position_value)
    camera.current = true
    return camera

func _sun() -> DirectionalLight3D:
    var sun := DirectionalLight3D.new()
    sun.name = "Sun"
    sun.rotation_degrees = Vector3(-50, -30, 0)
    sun.shadow_enabled = true
    return sun

func _contains_type(node: Node, type_name: String) -> bool:
    if node.is_class(type_name): return true
    for child in node.get_children():
        if _contains_type(child, type_name): return true
    return false

func _setup_project() -> void:
    if not ProjectSettings.has_setting("autoload/Rodot"):
        add_autoload_singleton("Rodot", "res://addons/rodot/runtime/runtime.gd")
        ProjectSettings.save()
    var root := get_editor_interface().get_edited_scene_root()
    if root == null:
        var path := "res://rodot_world.tscn"
        if not FileAccess.file_exists(path):
            var world := Node3D.new()
            world.name = "World"
            var floor_part := preload("../runtime/part.gd").new()
            floor_part.name = "Baseplate"
            floor_part.size = Vector3(24, 1, 24)
            floor_part.position.y = -1
            floor_part.anchored = true
            for child in [floor_part, _camera(), _sun()]:
                world.add_child(child)
                child.owner = world
            var scene := PackedScene.new()
            scene.pack(world)
            var error := ResourceSaver.save(scene, path)
            world.free()
            if error != OK:
                runtime_label.text = "Could not create the starter scene."
                runtime_label.show()
                return
        get_editor_interface().get_resource_filesystem().scan()
        get_editor_interface().open_scene_from_path(path)
        if str(ProjectSettings.get_setting("application/run/main_scene", "")).is_empty():
            ProjectSettings.set_setting("application/run/main_scene", path)
            ProjectSettings.save()
    elif root is Node3D:
        var additions: Array[Node] = []
        if not _contains_type(root, "Camera3D"): additions.append(_camera())
        if not _contains_type(root, "Light3D"): additions.append(_sun())
        if not additions.is_empty():
            var undo := get_undo_redo()
            undo.create_action("Set up Rodot")
            for child in additions:
                undo.add_do_method(root, "add_child", child, true)
                undo.add_do_method(child, "set_owner", root)
                undo.add_do_reference(child)
                undo.add_undo_method(root, "remove_child", child)
            undo.commit_action()
    runtime_label.text = "Ready" if ClassDB.class_exists("Luau") else "Restart Godot to finish setup."
    runtime_label.show()

func _button(text_value: String, callback: Callable, parent: Node) -> Button:
    var button := Button.new()
    button.text = text_value
    button.pressed.connect(callback)
    parent.add_child(button)
    return button

func _build_dock() -> void:
    dock = VBoxContainer.new()
    dock.name = "Rodot"
    dock.custom_minimum_size = Vector2(210, 120)
    var logo := TextureRect.new()
    var image := Image.new()
    image.load_svg_from_string(FileAccess.get_file_as_string("res://addons/rodot/branding/Rodot.svg"), 0.25)
    logo.texture = ImageTexture.create_from_image(image)
    logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    logo.custom_minimum_size.y = 48
    dock.add_child(logo)
    var actions := HBoxContainer.new()
    dock.add_child(actions)
    _button("Set up", _setup_project, actions).size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _button("Scripts", _show_luau, actions).size_flags_horizontal = Control.SIZE_EXPAND_FILL
    edit_button = _button("Edit", _edit_selected, dock)
    runtime_label = Label.new()
    runtime_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    runtime_label.hide()
    dock.add_child(runtime_label)
    add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
    set_dock_tab_icon(dock, rodot_icon)
func _selected_node() -> Node:
    var nodes := get_editor_interface().get_selection().get_selected_nodes()
    return nodes[0] if not nodes.is_empty() else null

func _refresh_scene_ui() -> void:
    if not is_instance_valid(workspace) or not is_instance_valid(edit_button): return
    var root := get_editor_interface().get_edited_scene_root()
    var selected := _selected_node()
    workspace.set_scene_context(root, selected)
    edit_button.visible = selected != null and selected.has_method("is_module_script")
    if edit_button.visible: edit_button.tooltip_text = selected.source
func _edit_selected() -> void:
    var node := _selected_node()
    if node != null and node.has_method("is_module_script"): _open_scene_script(node.get_instance_id())

func _attach_script() -> void:
    var root := get_editor_interface().get_edited_scene_root()
    var path: String = workspace.current_path()
    if root == null or path.is_empty(): return
    var parent := _selected_node()
    if parent == null: parent = root
    for child in parent.get_children():
        if child.get_script() == preload("../runtime/script.gd") and child.source == path:
            get_editor_interface().get_selection().clear()
            get_editor_interface().get_selection().add_node(child)
            return
    var runner := preload("../runtime/script.gd").new()
    runner.name = path.get_file().get_basename().validate_node_name()
    runner.source = path
    var undo := get_undo_redo()
    undo.create_action("Attach Rodot Luau script")
    undo.add_do_method(parent, "add_child", runner, true)
    undo.add_do_method(runner, "set_owner", root)
    undo.add_do_method(self, "call_deferred", "_refresh_scene_ui")
    undo.add_do_reference(runner)
    undo.add_undo_method(parent, "remove_child", runner)
    undo.add_undo_method(self, "call_deferred", "_refresh_scene_ui")
    undo.commit_action()

func _exit_tree() -> void:
    if supabase_setup != null: supabase_setup.uninstall(self)
    if is_instance_valid(runtime_debugger):
        runtime_debugger.close()
        remove_debugger_plugin(runtime_debugger)
    if is_instance_valid(attributes_inspector): remove_inspector_plugin(attributes_inspector)
    if scene_actions != null: scene_actions.uninstall()
    _show_native()
    if is_instance_valid(file_menu): remove_context_menu_plugin(file_menu)
    remove_export_plugin(source_exporter)
    remove_custom_type("RodotScript")
    remove_custom_type("Part")
    remove_custom_type("RodotInstance")
    remove_custom_type("RodotModuleScript")
    remove_custom_type("ParticleEmitter")
    remove_custom_type("RodotDecal")
    remove_custom_type("Attachment")
    remove_custom_type("Beam")
    remove_custom_type("Trail")
    remove_custom_type("Sound")
    if is_instance_valid(dock):
        remove_control_from_docks(dock)
        dock.queue_free()
    if is_instance_valid(workspace): workspace.queue_free()

