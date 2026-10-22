#pragma once

#ifdef __APPLE__
#include <Python.h>

void native_sidebar_set_callback(PyObject *callback);
void native_sidebar_set_data(void *glfw_window, unsigned long long os_window_id, const char *payload, int width_pt);
void native_sidebar_set_visible(void *glfw_window, int visible);
void native_sidebar_begin_rename_project(void *glfw_window, unsigned long long os_window_id, const char *project_id);
#endif
