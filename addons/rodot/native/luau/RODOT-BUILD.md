# Rodot Windows runtime

`bin/rodot_luau.windows.x86_64.dll` is rebuilt from [Luau GDExtension](https://github.com/fernforestgames/luau-gdextension) 0.6.1, commit `bc1b88da7121a6b049094a5eebc7e5b359bc8ac3`.

The included `rodot-object-binding.patch` removes one invalid binding: `LuaState::to_string` resolves to the inherited `Object::to_string`, which godot-cpp cannot register through its custom class table. This caused the reported `Class 'Object' doesn't exist` startup error. `to_string_inplace` remains available and unchanged. No errors are suppressed.

Dependencies:

- godot-cpp godot-4.5-stable, commit `e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77`
- Luau 0.719, commit `54426c4217740440c25d51fd579a4746028551c3`

Built on Windows x86-64 using MSVC 14.51, CMake, Ninja, Python 3.12, Release configuration, `BUILD_TESTING=OFF`, and `LIBRARY_SUFFIX=dll`. Dependency source directories were supplied through CMake's `FETCHCONTENT_SOURCE_DIR_GODOTCPP` and `FETCHCONTENT_SOURCE_DIR_LUAU`. The Windows debug and release extension entries both select this binary. Extension hot reloading is disabled.

The original MIT license is retained in `LICENSE`. Dependency licenses are included as `LICENSE-godot-cpp.md`, `LICENSE-Luau.txt`, and `LICENSE-Lua.txt`.

Linux and macOS binaries are unchanged upstream 0.6.1 builds. They have not received this patch or been tested here. Exported application builds remain unverified.
