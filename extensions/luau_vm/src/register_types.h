#pragma once

#include <godot_cpp/core/class_db.hpp>

void initialize_luau_vm_module(godot::ModuleInitializationLevel p_level);
void uninitialize_luau_vm_module(godot::ModuleInitializationLevel p_level);
