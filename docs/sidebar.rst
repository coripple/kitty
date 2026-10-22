Project sidebar
===============

ditty adds a project-oriented sidebar on the left edge of every OS window. Each
project is a directory backed by a kitty session file. Tabs opened inside a
project are tagged with that project, so the sidebar can group live tabs by
project and ditty can save and restore each project independently.

Creating projects
------------------

Click the :guilabel:`+` button next to the :guilabel:`Projects` header at the
top of the sidebar (or choose :guilabel:`New Project` from the sidebar's context
menu) to create a project for the working directory of the active window. You can also use the
:ac:`new_project` action, optionally with a directory and a name::

    map kitty_mod+shift+n new_project
    # or explicitly
    map kitty_mod+shift+n new_project /path/to/project "My project"

The first time ditty starts with an empty project index, it creates a project
for the startup directory and attaches the initial tab to it. Subsequent
startups attach the fresh tab to the most recently used project. The default
shortcuts are :kbd:`kitty_mod+Shift+N` for a new project and
:kbd:`kitty_mod+Shift+S` to save all projects immediately.

Switching projects
------------------

Click a project to focus it, loading its session file if it is not already
open. Tabs that already belong to the project stay alive in the current window;
switching projects does not kill any processes. Click the disclosure triangle
next to a project to collapse or expand its tab list; a collapsed project shows
its number of open tabs.

On macOS the sidebar also supports:

* Hovering a project shows a :guilabel:`+` button that opens a new tab in the
  project's directory.
* Hovering a tab shows a close button; middle-clicking a tab also closes it.
* Double-click a project (or choose :guilabel:`Rename…` from its context menu)
  to rename it inline. :kbd:`Return` confirms, :kbd:`Esc` cancels.
* Double-click a tab to rename it inline as well.
* Right-click a project for :guilabel:`New Tab`, :guilabel:`New Tab from
  Template`, :guilabel:`Rename…`, :guilabel:`Save as Template…`,
  :guilabel:`Show in Finder`, :guilabel:`Copy Path`, :guilabel:`Close All Tabs`
  and :guilabel:`Remove Project…`.
* Right-click a tab for :guilabel:`New Tab`, :guilabel:`New Tab from Template`,
  :guilabel:`Duplicate Tab`, :guilabel:`Rename Tab…`, :guilabel:`Reset Tab
  Title`, :guilabel:`Save as Template…`, :guilabel:`Move to Project`,
  :guilabel:`Move to New Window`, :guilabel:`Show Working Directory in Finder`,
  :guilabel:`Copy Working Directory`, :guilabel:`Close Other Tabs in Project`
  and :guilabel:`Close Tab`.
* Right-click empty space or the :guilabel:`Projects` header for
  :guilabel:`New Project from Folder…`.
* Drag the right edge of the sidebar to resize it. Dragging it almost closed
  hides the sidebar; double-clicking the edge restores the default width
  (:opt:`sidebar_native_width`).
* Show or hide the sidebar with the button next to the window controls in the
  titlebar, with :kbd:`Ctrl+Cmd+S` (the :ac:`toggle_sidebar` action), or with
  :guilabel:`Hide Sidebar` in the sidebar's context menu.

The sidebar width and whether it is hidden are remembered across restarts, in
the project index.

Templates
---------

Templates are ordinary kitty session files in :file:`sessions` inside the
ditty config directory (for example :file:`~/.config/ditty/sessions`), the same
directory you can browse with::

    map f7>l goto_session ~/.config/ditty/sessions

:guilabel:`Save as Template…` on a tab or project writes its layout, working
directories and foreground programs there (like ``save_as_session
--use-foreground-process``), so it immediately shows up in that list.
:guilabel:`New Tab from Template` opens the tabs of a template inside the
project; tabs that do not ``cd`` anywhere start in the project directory. Hold
:kbd:`Option` in that menu to edit a template instead. Set the
:envvar:`DITTY_TEMPLATES_DIR` environment variable to use a different
directory.

Opening, closing and deleting projects
---------------------------------------

The :guilabel:`Projects` group lists the open projects, those with tabs. A
project you close moves to the :guilabel:`Recent` group below it, most recently
used first, showing when it was last opened. Click a recent project to open it
again; its tabs are restored from its saved session.

:guilabel:`Close Project` (context menu, or the :ac:`close_project` action, which
closes the project of the active tab when given no argument) saves the project
and closes its tabs, asking for confirmation if programs are still running.
:guilabel:`Delete Project…` removes the project from the sidebar, closes its
tabs and moves its saved session file to the Trash. The project directory itself
is never touched.

Saving
------

Project state is saved automatically after tabs are created, closed,
re-ordered or when a session is loaded. Saves are debounced (see
:opt:`sidebar_autosave_delay`) and written atomically. Use the
:ac:`save_projects` action to force an immediate save::

    map kitty_mod+shift+s save_projects

The saved session contains the tab layout, working directories, foreground
commands (subject to the usual :ac:`save_as_session` rules) and tab titles. It
does not contain the scrollback or the memory of running processes.

Configuration
-------------

All options are in the ``sidebar`` group: :opt:`sidebar_enabled`,
:opt:`sidebar_native`, :opt:`sidebar_native_width`, :opt:`sidebar_width`,
:opt:`sidebar_autosave`, :opt:`sidebar_autosave_delay` and
:opt:`sidebar_show_new_project_button`.

On macOS the sidebar is a native AppKit source list using the system sidebar
material. It extends up through the titlebar, dims with the window when it is
not focused and follows the :guilabel:`Sidebar icon size` setting in System
Settings, so it looks like the sidebar in Finder or Mail. Set :opt:`sidebar_native` to :code:`no` to fall back to
rendering the project tree as terminal cells in a vertical tab bar. On other
platforms the terminal-cell fallback is used automatically, with the tab bar
forced to the left edge and always visible, even with one tab.

Projects can be renamed or deleted with the :ac:`rename_project` and
:ac:`delete_project` actions. Deleting a project removes it from the sidebar
and closes its tabs by default (pass ``--keep-tabs`` to keep them); the session
file is left on disk so it can be recovered manually.

Project data is stored in :file:`projects` inside the ditty config directory,
for example :file:`~/.config/ditty/projects` (set :envvar:`DITTY_PROJECTS_DIR`
to use another directory). :file:`index.json` lists the projects (name,
directory, last use, whether it was open) and the sidebar width and visibility.
Each project's tabs are saved in a ``<name>-<id>.kitty-session`` file next to it:
layout, working directories, titles and ssh kitten connections, which reconnect
on restore. Other running programs are not re-run. The files are plain kitty
session files and can also be used with ``ditty --session`` directly. Templates
live in :file:`sessions` next to :file:`projects`.
