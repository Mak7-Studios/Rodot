@tool
extends CodeEdit

var completion_model: RefCounted
var changed_callback: Callable
signal font_size_changed(size: int)
var default_font_size := 16

func _ready() -> void:
	custom_minimum_size = Vector2(240, 240)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	gutters_draw_line_numbers = true
	gutters_draw_fold_gutter = true
	line_folding = true
	indent_automatic = true
	indent_use_spaces = true
	indent_size = 4
	auto_brace_completion_enabled = true
	auto_brace_completion_highlight_matching = true
	code_completion_enabled = true
	code_completion_prefixes = [".", ":", '"', "'"]
	highlight_current_line = true
	highlight_all_occurrences = true
	draw_tabs = false
	draw_spaces = false
	minimap_draw = true
	minimap_width = 90
	scroll_past_end_of_file = true
	caret_blink = true
	default_font_size = get_theme_font_size("font_size")
	add_comment_delimiter("--[[", "]]", false)
	add_comment_delimiter("--", "", true)
	var highlighter := CodeHighlighter.new()
	highlighter.number_color = Color("f6bc80")
	highlighter.function_color = Color("78bdf2")
	highlighter.symbol_color = Color("c4c9d4")
	highlighter.member_variable_color = Color("c4d6f5")
	for keyword in ["local", "function", "end", "if", "then", "else", "elseif", "for", "while", "do", "repeat", "until", "return", "break", "continue", "and", "or", "not", "in", "nil", "true", "false", "type", "export"]:
		highlighter.add_keyword_color(keyword, Color("d59cfa"))
	if completion_model != null:
		for builtin in completion_model.globals: highlighter.add_keyword_color(builtin, Color("82daca"))
		for property in completion_model.properties: highlighter.add_member_keyword_color(property, Color("a9caff"))
	for type_name in ["number", "string", "boolean", "any", "unknown", "never", "thread"]: highlighter.add_keyword_color(type_name, Color("82daca"))
	highlighter.add_color_region("--[[", "]]", Color("7d899c"))
	highlighter.add_color_region("--", "", Color("7d899c"), true)
	highlighter.add_color_region('"', '"', Color("b5d59a"))
	highlighter.add_color_region("'", "'", Color("b5d59a"))
	highlighter.add_color_region("[[", "]]", Color("b5d59a"))
	highlighter.add_color_region("`", "`", Color("b5d59a"))
	syntax_highlighter = highlighter
	code_completion_requested.connect(_complete)
	caret_changed.connect(func():
		if completion_model != null: set_code_hint(completion_model.call_hint(before_caret()))
	)
	text_changed.connect(func():
		if changed_callback.is_valid(): changed_callback.call()
		request_code_completion(false)
	)

func before_caret() -> String:
	var lines := text.split("\n")
	var before := ""
	for i in range(get_caret_line()): before += lines[i] + "\n"
	return before + get_line(get_caret_line()).left(get_caret_column())

func _complete() -> void:
	if completion_model == null: return
	if is_in_comment(get_caret_line(), get_caret_column()) >= 0: return
	var options: Dictionary = completion_model.suggestions(before_caret())
	for name in options:
		var entry: Dictionary = options[name]
		add_code_completion_option(entry.kind, entry.signature if not entry.signature.is_empty() else name, name, Color("dce2ed"), null, entry.signature if not entry.signature.is_empty() else entry.type)
	update_code_completion_options(true)

func _word_character(character: String) -> bool:
	return character == "_" or character >= "a" and character <= "z" or character >= "A" and character <= "Z" or character >= "0" and character <= "9"

func _confirm_code_completion(replace: bool) -> void:
	var selected := get_code_completion_selected_index()
	if selected < 0: return
	var option := get_code_completion_option(selected)
	var line := get_caret_line()
	var column := get_caret_column()
	var source := get_line(line)
	var start := column
	var end := column
	while start > 0 and _word_character(source.substr(start - 1, 1)): start -= 1
	if replace:
		while end < source.length() and _word_character(source.substr(end, 1)): end += 1
	var insertion: String = option.insert_text
	var add_parentheses: bool = option.kind == KIND_FUNCTION and not source.substr(end).begins_with("(")
	if add_parentheses: insertion += "()"
	cancel_code_completion()
	begin_complex_operation()
	select(line, start, line, end)
	set_caret_line(line)
	set_caret_column(end)
	insert_text_at_caret(insertion)
	if add_parentheses: set_caret_column(get_caret_column() - 1)
	end_complex_operation()

func handle_zoom(event: InputEvent) -> bool:
	if not event is InputEventWithModifiers or not event.is_command_or_control_pressed(): return false
	var amount := 0
	var reset := false
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: amount = 1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: amount = -1
	elif event is InputEventKey and event.pressed:
		if event.keycode in [KEY_PLUS, KEY_EQUAL, KEY_KP_ADD]: amount = 1
		elif event.keycode in [KEY_MINUS, KEY_KP_SUBTRACT]: amount = -1
		elif event.keycode in [KEY_0, KEY_KP_0]: reset = true
	if amount == 0 and not reset: return false
	var size_value := default_font_size if reset else clampi(get_theme_font_size("font_size") + amount, 9, 48)
	add_theme_font_size_override("font_size", size_value)
	font_size_changed.emit(size_value)
	return true

func _gui_input(event: InputEvent) -> void:
	if handle_zoom(event): accept_event()
