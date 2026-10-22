#!/usr/bin/env python
# License: GPL v3 Copyright: 2026


"""Project management for ditty.

A project is a directory backed by a kitty session file. Tabs created inside a
project are tagged with the project's session name, which lets the sidebar
group live tabs by project and lets kitty's existing session machinery
snapshot and restore them.
"""

import json
import os
import re
import shlex
import time
import uuid
from dataclasses import asdict, dataclass, field
from typing import TYPE_CHECKING, Iterable, NamedTuple

from .constants import appname, config_dir, is_macos
from .utils import log_error

if TYPE_CHECKING:
    from .boss import Boss
    from .tab_bar import TabBarData
    from .tabs import Tab

SESSION_EXTENSION = '.kitty-session'
MIN_SIDEBAR_WIDTH = 150
MAX_SIDEBAR_WIDTH = 600


def state_dir() -> str:
    return config_dir


def _migrate_legacy_projects(dest: str) -> None:
    """One-time move from the old macOS Application Support location."""
    if not is_macos:
        return
    legacy = os.path.join(os.path.expanduser('~/Library/Application Support'), appname, 'projects')
    if os.path.abspath(legacy) == os.path.abspath(dest):
        return
    if not os.path.isdir(legacy) or os.path.exists(os.path.join(dest, 'index.json')):
        return
    try:
        import shutil

        shutil.copytree(legacy, dest, dirs_exist_ok=True)
        idx = os.path.join(dest, 'index.json')
        if os.path.exists(idx):
            with open(idx, encoding='utf-8') as f:
                data = json.load(f)
            for p in data.get('projects', ()):
                sp = p.get('session_path')
                if sp:
                    p['session_path'] = os.path.join(dest, os.path.basename(sp))
            with open(idx, 'w', encoding='utf-8') as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
        log_error(f'Migrated ditty projects from {legacy} to {dest}')
    except Exception as e:
        log_error(f'Failed to migrate ditty projects from {legacy} to {dest}: {e}')


def templates_dir() -> str:
    '''Directory of tab templates. These are ordinary kitty session files, the
    same directory that ``goto_session ~/.config/ditty/sessions`` lists.'''
    override = os.environ.get('DITTY_TEMPLATES_DIR')
    if override:
        return os.path.abspath(os.path.expanduser(override))
    return os.path.join(config_dir, 'sessions')


_templates_cache: tuple[str, float, list[dict[str, str]]] | None = None


def list_templates() -> list[dict[str, str]]:
    global _templates_cache
    from .session import has_session_extension, session_arg_to_name

    d = templates_dir()
    try:
        mtime = os.stat(d).st_mtime
    except OSError:
        return []
    if _templates_cache is not None and _templates_cache[0] == d and _templates_cache[1] == mtime:
        return _templates_cache[2]
    ans: list[dict[str, str]] = []
    try:
        with os.scandir(d) as entries:
            for entry in entries:
                if entry.is_file() and has_session_extension(entry.name):
                    name = session_arg_to_name(entry.path)
                    if name:
                        ans.append({'name': name, 'path': entry.path})
    except OSError as e:
        log_error(f'Failed to list templates in {d}: {e}')
        return []
    ans.sort(key=lambda x: x['name'].lower())
    _templates_cache = d, mtime, ans
    return ans


def template_path_for_name(name: str) -> str:
    name = name.strip().replace(os.sep, '-')
    if name.lower().endswith(SESSION_EXTENSION):
        name = name[: -len(SESSION_EXTENSION)]
    return os.path.join(templates_dir(), name + SESSION_EXTENSION)


def projects_dir() -> str:
    override = os.environ.get('DITTY_PROJECTS_DIR')
    if override:
        ans = os.path.abspath(os.path.expanduser(override))
        os.makedirs(ans, exist_ok=True)
        return ans
    ans = os.path.join(config_dir, 'projects')
    os.makedirs(ans, exist_ok=True)
    _migrate_legacy_projects(ans)
    return ans


def index_path() -> str:
    return os.path.join(projects_dir(), 'index.json')


@dataclass
class Project:
    id: str
    name: str
    root: str
    session_name: str
    session_path: str
    expanded: bool = True
    last_opened: float = 0.0
    created_at: float = field(default_factory=time.time)
    # Whether the project had tabs when ditty last saved, so that it can be
    # restored at the next startup.
    open_at_exit: bool = False

    @property
    def display_name(self) -> str:
        return self.name or os.path.basename(self.root) or self.id


class SidebarGroup(NamedTuple):
    project: Project | None
    session_name: str
    tabs: list['TabBarData']


def _slugify(name: str) -> str:
    ans = re.sub(r'[^A-Za-z0-9_.-]+', '-', name).strip('-').lower()
    return ans[:32] or 'project'


def native_sidebar_active() -> bool:
    from .fast_data_types import get_options

    opts = get_options()
    return bool(is_macos and opts.sidebar_enabled and opts.sidebar_native)


def _clean_title(text: str) -> str:
    text = re.sub(r'\x1b\[[0-9;:?]*[ -/]*[@-~]', '', text)
    return text.replace('\n', ' ').replace('\r', ' ')


def _has_custom_title(tab_id: int) -> bool:
    from .fast_data_types import get_boss

    boss = get_boss()
    tab = boss.tab_for_id(tab_id) if boss is not None else None
    return bool(tab is not None and tab.name)


def _has_remembered_ssh(tab_id: int) -> bool:
    from .fast_data_types import get_boss

    boss = get_boss()
    tab = boss.tab_for_id(tab_id) if boss is not None else None
    return tab is not None and any(w.remembered_ssh_cmdline for w in tab)


def native_sidebar_rows(data: Iterable['TabBarData']) -> list[dict[str, object]]:
    from .fast_data_types import get_options

    pm = get_project_manager()
    rows: list[dict[str, object]] = []
    closed: list[Project] = []
    for g in pm.sidebar_groups(data):
        has_active = any(t.is_active for t in g.tabs)
        if g.project is not None:
            p = g.project
            if not g.tabs and not pm.has_live_tabs(p):
                # Closed projects are listed under "Recent" instead
                closed.append(p)
                continue
            rows.append(
                {
                    'kind': 'project',
                    'id': p.id,
                    'title': _clean_title(p.display_name),
                    'root': p.root,
                    'session_path': p.session_path,
                    'open': True,
                    'expanded': p.expanded,
                    'active': has_active,
                    'count': len(g.tabs),
                }
            )
            # Always send the tabs: the native outline view collapses them
            # itself so that the disclosure animation is not interrupted.
            for t in g.tabs:
                rows.append(
                    {
                        'kind': 'tab',
                        'id': str(t.tab_id),
                        'project_id': p.id,
                        'title': _clean_title(t.title),
                        'active': t.is_active,
                        'custom_title': _has_custom_title(t.tab_id),
                        'ssh': _has_remembered_ssh(t.tab_id),
                    }
                )
        else:
            rows.append(
                {
                    'kind': 'section',
                    'id': '',
                    'title': _clean_title(g.session_name or 'Unfiled'),
                    'expanded': True,
                    'active': has_active,
                    'count': len(g.tabs),
                }
            )
            for t in g.tabs:
                rows.append(
                    {
                        'kind': 'tab',
                        'id': str(t.tab_id),
                        'project_id': '',
                        'title': _clean_title(t.title),
                        'active': t.is_active,
                    }
                )
    closed.sort(key=lambda p: p.last_opened, reverse=True)
    for p in closed:
        rows.append(
            {
                'kind': 'project',
                'id': p.id,
                'title': _clean_title(p.display_name),
                'root': p.root,
                'session_path': p.session_path,
                'open': False,
                'last_opened': p.last_opened,
                'expanded': False,
                'active': False,
                'count': 0,
            }
        )
    if get_options().sidebar_show_new_project_button:
        rows.append({'kind': 'new_project', 'id': '', 'title': 'New project', 'active': False})
    return rows


def update_native_sidebar(os_window_id: int, data: Iterable['TabBarData']) -> None:
    from .fast_data_types import get_options, sidebar_set_native_data

    opts = get_options()
    pm = get_project_manager()
    rows = native_sidebar_rows(data)
    payload = json.dumps(
        {'rows': rows, 'hidden': pm.sidebar_hidden, 'templates': list_templates(), 'templates_dir': templates_dir()},
        ensure_ascii=False,
    )
    sidebar_set_native_data(os_window_id, payload, pm.effective_sidebar_width(opts.sidebar_native_width))


def _activate_tab(pm: 'ProjectManager', boss: 'Boss', tab: 'Tab', project_id: str, text: str) -> None:
    tm = tab.tab_manager_ref()
    if tm is not None:
        tm.set_active_tab(tab)


def _close_tab(pm: 'ProjectManager', boss: 'Boss', tab: 'Tab', project_id: str, text: str) -> None:
    if text == 'confirmed':
        # The sidebar already asked. Closing the last tab from the sidebar
        # must not quit ditty.
        pm._keep_os_windows_open([tab])
        boss.close_tab_no_confirm(tab)
    else:
        boss.close_tab(tab)


def _rename_tab(pm: 'ProjectManager', boss: 'Boss', tab: 'Tab', project_id: str, text: str) -> None:
    # An empty name resets the tab to its automatic title
    tab.set_title(text.strip())
    pm.schedule_save()


def _move_tab(pm: 'ProjectManager', boss: 'Boss', tab: 'Tab', project_id: str, text: str) -> None:
    if (p := pm.by_id(project_id)) is not None:
        pm.attach_tab(tab, p)
        p.expanded = True
        pm.save_index()
        pm.schedule_save()
        pm.redraw()


def _tab_cwd(tab: 'Tab') -> str:
    w = tab.active_window
    return (w.cwd_of_child if w is not None else '') or ''


def _show_tab_cwd(pm: 'ProjectManager', boss: 'Boss', tab: 'Tab', project_id: str, text: str) -> None:
    if cwd := _tab_cwd(tab):
        boss.open_url(cwd)


def _copy_tab_cwd(pm: 'ProjectManager', boss: 'Boss', tab: 'Tab', project_id: str, text: str) -> None:
    from .clipboard import set_clipboard_string

    if cwd := _tab_cwd(tab):
        set_clipboard_string(cwd)


def _detach_tab(pm: 'ProjectManager', boss: 'Boss', tab: 'Tab', project_id: str, text: str) -> None:
    boss._move_tab_to(tab)


def _close_other_tabs(pm: 'ProjectManager', boss: 'Boss', tab: 'Tab', project_id: str, text: str) -> None:
    for other in list(boss.all_tabs):
        if other is not tab and other.created_in_session_name == tab.created_in_session_name:
            if text == 'confirmed':
                boss.close_tab_no_confirm(other)
            else:
                boss.close_tab(other)


def _reconnect_ssh(pm: 'ProjectManager', boss: 'Boss', tab: 'Tab', project_id: str, text: str) -> None:
    '''Re-run the remembered ssh command in windows of the tab that are back
    at a local shell prompt, e.g. after returning to the office network.'''
    for w in tab:
        if w.remembered_ssh_cmdline and w.at_prompt and not w.ssh_kitten_cmdline():
            w.write_to_child((shlex.join(w.remembered_ssh_cmdline) + '\r').encode())


_TAB_ACTIONS = {
    'tab': _activate_tab,
    'close_tab': _close_tab,
    'rename_tab': _rename_tab,
    'move_tab': _move_tab,
    'show_tab_cwd': _show_tab_cwd,
    'copy_tab_cwd': _copy_tab_cwd,
    'detach_tab': _detach_tab,
    'close_other_tabs': _close_other_tabs,
    'reconnect_ssh': _reconnect_ssh,
    'duplicate_tab': lambda pm, boss, tab, project_id, text: pm.duplicate_tab(tab),
    'save_tab_template': lambda pm, boss, tab, project_id, text: pm.save_tab_as_template(tab, text),
}


def _int_or_zero(text: str) -> int:
    try:
        return int(float(text))
    except ValueError:
        return 0


def native_sidebar_action(kind: str, project_id: str, tab_id: int, text: str = '') -> None:
    from .fast_data_types import get_boss

    boss = get_boss()
    if boss is None:
        return
    pm = get_project_manager()
    if kind == 'new_project':
        pm.new_project_from_active_window()
    elif kind == 'toggle_project':
        pm.toggle_expanded(project_id)
    elif kind == 'set_expanded':
        pm.set_expanded(project_id, text == '1')
    elif kind == 'project':
        pm.activate(project_id)
    elif kind == 'new_tab':
        pm.new_tab_in_project(project_id)
    elif kind == 'rename_project':
        pm.rename_project(project_id, text.strip())
    elif kind == 'rename_tab':
        tab = boss.tab_for_id(int(tab_id))
        if tab is not None:
            tab.set_title(text.strip())
            pm.schedule_save()
    elif kind == 'delete_project':
        pm.delete_project(project_id, close_tabs=True)
    elif kind == 'new_project_dir':
        if text and os.path.isdir(text):
            pm.new_project(text, activate=True)
    elif kind in ('close_project', 'close_project_tabs'):
        pm.close_project(project_id)
    elif kind == 'new_tab_from_template':
        pm.new_tab_from_template(project_id, text)
    elif kind == 'save_project_template':
        pm.save_project_as_template(project_id, text)
    elif kind == 'edit_template':
        if text:
            boss.edit_file(text)
    elif kind == 'sidebar_resize':
        pm.set_sidebar_width(_int_or_zero(text), persist=False)
    elif kind == 'sidebar_width':
        pm.set_sidebar_width(_int_or_zero(text), persist=True)
    elif kind == 'sidebar_hidden':
        pm.set_sidebar_hidden(text == '1')
    elif kind in _TAB_ACTIONS:
        tab = boss.tab_for_id(int(tab_id))
        if tab is None:
            return
        _TAB_ACTIONS[kind](pm, boss, tab, project_id, text)
    else:
        log_error(f'Unknown native sidebar action: {kind}')


class ProjectManager:
    def __init__(self) -> None:
        self.projects: list[Project] = []
        # Width of the native sidebar in points, 0 means use sidebar_native_width
        self.sidebar_width = 0
        self.sidebar_hidden = False
        # Session names of projects whose tabs are being closed. Their session
        # file was saved before closing started and must not be overwritten
        # with the partially closed state.
        self._closing: set[str] = set()
        self._save_timer: int | None = None
        self._periodic_timer: int | None = None
        self.adopted_sessions: dict[str, str] = {}
        self.load()

    # index {{{

    def load(self) -> None:
        path = index_path()
        try:
            with open(path, encoding='utf-8') as f:
                raw = json.load(f)
        except FileNotFoundError:
            return
        except Exception as e:
            log_error(f'Ignoring damaged project index {path}: {e}')
            return
        sidebar = raw.get('sidebar')
        if isinstance(sidebar, dict):
            try:
                self.sidebar_width = max(0, int(sidebar.get('width', 0)))
            except (TypeError, ValueError):
                self.sidebar_width = 0
            self.sidebar_hidden = bool(sidebar.get('hidden', False))
        self._push_sidebar_layout()
        seen: set[str] = set()
        for item in raw.get('projects', ()):
            try:
                p = Project(
                    id=str(item['id']),
                    name=str(item.get('name') or ''),
                    root=str(item['root']),
                    session_name=str(item['session_name']),
                    session_path=str(item['session_path']),
                    expanded=bool(item.get('expanded', True)),
                    last_opened=float(item.get('last_opened', 0)),
                    created_at=float(item.get('created_at', time.time())),
                    open_at_exit=bool(item.get('open_at_exit', False)),
                )
            except Exception:
                continue
            if p.id not in seen:
                seen.add(p.id)
                self.projects.append(p)
        raw_adopted = raw.get('adopted_sessions', {})
        if isinstance(raw_adopted, dict):
            self.adopted_sessions = {str(k): str(v) for k, v in raw_adopted.items()}

    def save_index(self) -> None:
        from .config import atomic_save

        os.makedirs(projects_dir(), exist_ok=True)
        data = {
            'version': 1,
            'sidebar': {'width': self.sidebar_width, 'hidden': self.sidebar_hidden},
            'projects': [asdict(p) for p in self.projects],
            'adopted_sessions': self.adopted_sessions,
        }
        atomic_save(json.dumps(data, indent=2, ensure_ascii=False).encode('utf-8'), index_path())

    # }}}

    # lookup {{{

    def by_id(self, project_id: str) -> Project | None:
        for p in self.projects:
            if p.id == project_id:
                return p
        return None

    def by_session(self, session_name: str) -> Project | None:
        for p in self.projects:
            if p.session_name == session_name:
                return p
        return None

    def find(self, id_or_name: str) -> Project | None:
        for p in self.projects:
            if p.id == id_or_name or p.session_name == id_or_name or p.name == id_or_name:
                return p
        return None

    def redraw(self) -> None:
        from .fast_data_types import get_boss

        boss = get_boss()
        if boss is not None:
            for tm in boss.all_tab_managers:
                tm.mark_tab_bar_dirty()

    def has_live_tabs(self, project: Project) -> bool:
        from .fast_data_types import get_boss

        boss = get_boss()
        return boss is not None and any(t.created_in_session_name == project.session_name for t in boss.all_tabs)

    def sidebar_groups(self, data: Iterable['TabBarData']) -> list[SidebarGroup]:
        tabs = list(data)
        known: set[str] = set()
        ans: list[SidebarGroup] = []
        for p in self.projects:
            known.add(p.session_name)
            ans.append(SidebarGroup(p, p.session_name, [t for t in tabs if t.session_name == p.session_name]))
        extras: dict[str, list[TabBarData]] = {}
        for t in tabs:
            if t.session_name and t.session_name not in known:
                extras.setdefault(t.session_name, []).append(t)
        for session_name, group_tabs in extras.items():
            ans.append(SidebarGroup(None, session_name, group_tabs))
        unfiled = [t for t in tabs if not t.session_name]
        if unfiled:
            ans.append(SidebarGroup(None, '', unfiled))
        return ans

    # }}}

    # templates {{{

    def _add_session_tabs(self, raw: str, session_path: str, project: Project | None) -> list['Tab']:
        '''Parse session file text and add its tabs to the active OS window,
        attached to the project. Returns the new tabs.'''
        from .fast_data_types import get_boss, get_options
        from .session import parse_session

        boss = get_boss()
        tm = boss.active_tab_manager if boss is not None else None
        if tm is None:
            return []
        root = project.root if project is not None and os.path.isdir(project.root) else ''
        before = {t.id for t in tm}
        # session_arg is empty so the template does not become a session of its own
        for s in parse_session(raw, get_options(), session_path=session_path):
            if root:
                # Tabs in templates without a cd line start in the project directory
                for st in s.tabs:
                    if st.cwd is None:
                        st.cwd = root
                    for ws in st.windows:
                        opts = getattr(ws.launch_spec, 'opts', None)
                        if opts is not None and not opts.cwd:
                            opts.cwd = root
            tm.add_tabs_from_session(s, project.session_name if project is not None else '')
        added = [t for t in tm if t.id not in before]
        if project is not None:
            for t in added:
                self.attach_tab(t, project)
            project.expanded = True
            project.last_opened = time.time()
            self.save_index()
        self.schedule_save()
        self.redraw()
        return added

    def new_tab_from_template(self, project_id: str, path: str) -> None:
        from .fast_data_types import get_boss

        boss = get_boss()
        if boss is None or not path:
            return
        try:
            with open(path, encoding='utf-8') as f:
                raw = f.read()
        except OSError as e:
            boss.show_error('Could not read template', f'{path}: {e}')
            return
        try:
            self._add_session_tabs(raw, path, self.by_id(project_id) if project_id else None)
        except Exception as e:
            boss.show_error('Invalid template', f'{os.path.basename(path)}: {e}')

    def duplicate_tab(self, tab: 'Tab') -> None:
        from .fast_data_types import get_boss

        boss = get_boss()
        if boss is None:
            return
        lines = self._serialize_tabs([tab])
        if not lines:
            return
        try:
            self._add_session_tabs('\n'.join(lines), '', self.by_session(tab.created_in_session_name))
        except Exception as e:
            boss.show_error('Could not duplicate tab', str(e))

    def _serialize_tabs(self, tabs: Iterable['Tab'], session_path: str = '') -> list[str]:
        from .session import default_save_as_session_opts

        opts = default_save_as_session_opts()
        opts.save_only = True
        # Same as the f7>s mapping: restart programs running in the shells
        opts.use_foreground_process = True
        lines: list[str] = []
        for tab in tabs:
            lines.extend(tab.serialize_state_as_session(session_path, None, opts))
        return lines

    def _write_template(self, name: str, tabs: list['Tab']) -> str:
        from .config import atomic_save

        name = name.strip()
        if not name:
            raise ValueError('The template name must not be empty')
        path = template_path_for_name(name)
        lines = self._serialize_tabs(tabs, path)
        if not lines:
            raise ValueError('There is nothing to save')
        os.makedirs(os.path.dirname(path), exist_ok=True)
        atomic_save(('\n'.join(lines).rstrip() + '\n').encode('utf-8'), path)
        global _templates_cache
        _templates_cache = None
        self.redraw()
        return path

    def save_tab_as_template(self, tab: 'Tab', name: str) -> None:
        self._save_template(name, [tab])

    def save_project_as_template(self, project_id: str, name: str) -> None:
        from .fast_data_types import get_boss

        boss = get_boss()
        p = self.by_id(project_id)
        if boss is None or p is None:
            return
        self._save_template(name, [t for t in boss.all_tabs if t.created_in_session_name == p.session_name])

    def _save_template(self, name: str, tabs: list['Tab']) -> None:
        from .fast_data_types import get_boss

        boss = get_boss()
        if boss is None:
            return
        try:
            path = self._write_template(name, tabs)
        except Exception as e:
            boss.show_error('Could not save template', str(e))
            return
        # Confirm with a desktop notification; clicking it opens the file.
        try:
            nm = boss.notification_manager
            cmd = nm.create_notification_cmd()
            cmd.title = f'Saved template “{os.path.basename(path).rpartition(".")[0]}”'
            cmd.body = 'It is now listed in the sidebar and by goto_session in the templates directory.'
            cmd.on_activation = lambda nc, which: boss.edit_file(path)
            nm.notify_with_command(cmd, 0)
        except Exception as e:
            log_error(f'Saved template to {path} but failed to send a notification: {e}')

    def close_project(self, id_or_name: str) -> bool:
        '''Save the project and close its tabs. It stays in the index and is
        listed under Recent in the sidebar, from where it can be re-opened.'''
        from .fast_data_types import get_boss

        boss = get_boss()
        p = self.find(id_or_name)
        if boss is None or p is None:
            return False
        # Save first so that the project is re-opened as it was
        self.save_project(p)
        p.last_opened = time.time()
        self.save_index()
        tabs = [t for t in boss.all_tabs if t.created_in_session_name == p.session_name]
        if tabs:
            from .fast_data_types import add_timer

            sn = p.session_name
            self._closing.add(sn)
            # If the user cancels closing a tab with a running program, resume
            # saving the project after a while.
            add_timer(lambda timer_id: self._closing.discard(sn), 60, False)
        self._keep_os_windows_open(tabs)
        # close_tab asks for confirmation when programs are still running
        for tab in tabs:
            boss.close_tab(tab)
        self.redraw()
        return True

    def _keep_os_windows_open(self, closing: Iterable['Tab']) -> None:
        '''Closing the last tab of an OS window closes the window, and closing
        the last window quits. When all tabs of a window are about to be
        closed, open a plain shell tab (not part of any project) first.'''
        from .fast_data_types import get_boss
        from .tabs import SpecialWindow

        boss = get_boss()
        if boss is None:
            return
        ids = {t.id for t in closing}
        if not ids:
            return
        for tm in list(boss.all_tab_managers):
            tabs = list(tm)
            if not tabs or not all(t.id in ids for t in tabs):
                continue
            tab = tm.new_tab(special_window=SpecialWindow(None, cwd=os.path.expanduser('~')))
            # new_tab() puts tabs in the active project, this one must not be
            tab.created_in_session_name = ''
            for w in tab:
                w.created_in_session_name = ''

    def project_for_tab(self, tab: 'Tab | None') -> Project | None:
        return self.by_session(tab.created_in_session_name) if tab is not None else None

    # }}}

    # sidebar geometry {{{

    def effective_sidebar_width(self, default_width: int | None = None) -> int:
        if default_width is None:
            from .fast_data_types import get_options

            default_width = int(get_options().sidebar_native_width)
        w = self.sidebar_width or int(default_width)
        return max(MIN_SIDEBAR_WIDTH, min(MAX_SIDEBAR_WIDTH, w))

    def _push_sidebar_layout(self) -> None:
        if not is_macos:
            return
        from .fast_data_types import sidebar_set_native_layout

        try:
            width = self.effective_sidebar_width()
        except RuntimeError:
            # Options are not available yet (for example while loading the
            # manager in a unit test). The real application pushes the layout
            # once options are set.
            return
        sidebar_set_native_layout(width, self.sidebar_hidden)

    def apply_sidebar_layout(self) -> None:
        '''Tell the C layout code about the sidebar geometry and re-layout every OS window.'''
        if not native_sidebar_active():
            return
        from .fast_data_types import get_boss

        self._push_sidebar_layout()
        boss = get_boss()
        if boss is None:
            return
        for tm in boss.all_tab_managers:
            tm.resize()
            tm.mark_tab_bar_dirty()

    def set_sidebar_width(self, width: int, persist: bool = True) -> None:
        # 0 resets to the sidebar_native_width option
        width = 0 if width <= 0 else max(MIN_SIDEBAR_WIDTH, min(MAX_SIDEBAR_WIDTH, width))
        changed = width != self.sidebar_width
        self.sidebar_width = width
        if changed:
            self.apply_sidebar_layout()
        if persist:
            self.save_index()

    def set_sidebar_hidden(self, hidden: bool) -> None:
        if hidden == self.sidebar_hidden:
            return
        self.sidebar_hidden = hidden
        self.apply_sidebar_layout()
        self.save_index()

    def toggle_sidebar(self) -> None:
        self.set_sidebar_hidden(not self.sidebar_hidden)

    # }}}

    # session adoption {{{

    def project_for_active_tab(self, boss: 'Boss') -> Project | None:
        p = self.by_session(boss.active_session)
        if p is not None:
            return p
        if self.projects:
            return max(self.projects, key=lambda x: x.last_opened)
        return None

    def adopted_target(self, session_name: str) -> Project | None:
        pid = self.adopted_sessions.get(session_name)
        return self.by_id(pid) if pid else None

    def adopt_loaded_session(self, boss: 'Boss', session_name: str, target: Project | None) -> bool:
        if target is None or self.by_session(session_name) is not None:
            return False
        adopted = []
        for tab in boss.all_tabs:
            if tab.created_in_session_name == session_name:
                tab.created_in_session_name = target.session_name
                for w in tab:
                    w.created_in_session_name = target.session_name
                adopted.append(tab)
        if not adopted:
            return False
        self.adopted_sessions[session_name] = target.id
        target.expanded = True
        target.last_opened = time.time()
        self.save_project(target)
        self.save_index()
        self.redraw()
        return True

    # }}}

    # creation {{{

    def initial_session_data(self, root: str) -> str:
        return shlex.join(('launch', f'--cwd={root}')) + '\n'

    def new_project(
        self, root: str, name: str = '', *, activate: bool = True, save_index: bool = True, begin_rename: bool = False
    ) -> Project:
        from .config import atomic_save

        root = os.path.abspath(os.path.expanduser(root))
        name = name or (os.path.basename(root.rstrip(os.sep)) or 'project')
        pid = uuid.uuid4().hex[:12]
        session_name = f'{_slugify(name)}-{pid}'
        session_path = os.path.join(projects_dir(), session_name + SESSION_EXTENSION)
        session_data = self.initial_session_data(root)
        atomic_save(session_data.encode('utf-8'), session_path)
        p = Project(id=pid, name=name, root=root, session_name=session_name, session_path=session_path, last_opened=time.time())
        self.projects.append(p)
        if save_index:
            self.save_index()
        self.redraw()
        if activate:
            self.open_project(p)
            if begin_rename and native_sidebar_active():
                self.begin_rename(p)
        return p

    def begin_rename(self, project: Project) -> None:
        from .fast_data_types import get_boss, sidebar_begin_rename_project

        boss = get_boss()
        if boss is None:
            return
        tm = boss.active_tab_manager
        if tm is not None:
            sidebar_begin_rename_project(tm.os_window_id, project.id)

    def new_project_from_active_window(self, name: str = '') -> Project | None:
        from .fast_data_types import get_boss

        boss = get_boss()
        if boss is None or (w := boss.active_window) is None:
            return None
        cwd = w.cwd_of_child or os.path.expanduser('~')
        return self.new_project(cwd, name, activate=True, begin_rename=not name)

    def new_project_from_args(self, args: Iterable[str]) -> Project | None:
        args = list(args)
        root: str
        name = ''
        if args:
            root = args[0]
            if len(args) > 1:
                name = args[1]
        else:
            from .fast_data_types import get_boss

            boss = get_boss()
            if boss is None or (w := boss.active_window) is None:
                return None
            root = w.cwd_of_child or os.path.expanduser('~')
        if not os.path.isdir(os.path.expanduser(root)):
            from .fast_data_types import get_boss

            boss = get_boss()
            if boss is not None:
                boss.show_error('Invalid project directory', f'{root} is not a directory')
            return None
        return self.new_project(root, name, activate=True, begin_rename=not name)

    def attach_tab(self, tab: 'Tab', project: Project) -> None:
        tab.created_in_session_name = project.session_name
        for w in tab:
            w.created_in_session_name = project.session_name

    # }}}

    # activation {{{

    def open_project(self, project: Project, *, create_if_missing: bool = True) -> bool:
        self._closing.discard(project.session_name)
        from .fast_data_types import get_boss
        from .session import create_session, switch_to_session

        boss = get_boss()
        if boss is None:
            return False
        project.expanded = True
        project.last_opened = time.time()
        self.save_index()
        if switch_to_session(boss, project.session_name):
            return True
        if not create_if_missing:
            return False
        if not os.path.exists(project.session_path):
            from .config import atomic_save

            atomic_save(self.initial_session_data(project.root).encode('utf-8'), project.session_path)
        try:
            create_session(boss, project.session_path)
            switch_to_session(boss, project.session_name)
        except Exception as e:
            log_error(f'Failed to open project {project.display_name}: {e}')
            return False
        self.redraw()
        return True

    def activate(self, project_id: str) -> None:
        if (p := self.by_id(project_id)) is not None:
            self.open_project(p)

    def toggle_expanded(self, project_id: str) -> None:
        if (p := self.by_id(project_id)) is not None:
            p.expanded = not p.expanded
            self.save_index()
            self.redraw()

    def set_expanded(self, project_id: str, expanded: bool) -> None:
        if (p := self.by_id(project_id)) is not None and p.expanded != expanded:
            p.expanded = expanded
            self.save_index()
            self.redraw()

    def new_tab_in_project(self, project_id: str) -> None:
        from .fast_data_types import get_boss
        from .tabs import SpecialWindow

        boss = get_boss()
        p = self.by_id(project_id)
        if boss is None or p is None:
            return
        if not self.has_live_tabs(p):
            # Nothing open yet: restore the project's saved session instead.
            self.open_project(p)
            return
        cwd = p.root if os.path.isdir(p.root) else None
        tab = boss._new_tab(SpecialWindow(None, cwd=cwd))
        if tab is None:
            return
        self.attach_tab(tab, p)
        p.expanded = True
        p.last_opened = time.time()
        self.save_index()
        self.schedule_save()
        self.redraw()

    # }}}

    # saving {{{

    def save_project(self, project: Project) -> bool:
        from .config import atomic_save
        from .fast_data_types import get_boss
        from .session import default_save_as_session_opts

        boss = get_boss()
        if boss is None:
            return False
        opts = default_save_as_session_opts()
        opts.save_only = True
        # Reconnect ssh kitten sessions (e.g. from templates that run
        # kitten ssh at shell startup) but do not re-run other programs.
        setattr(opts, 'preserve_ssh_kitten', True)
        # A tab belongs to a project, as shown in the sidebar, so save every
        # window of its tabs. Windows created without being tagged with the
        # project (for example splits launched without --cwd=current) would
        # otherwise be silently dropped.
        tabs = [t for t in boss.all_tabs if t.created_in_session_name == project.session_name]
        for t in tabs:
            for w in t:
                if not w.created_in_session_name:
                    w.created_in_session_name = project.session_name
        matched = frozenset(w for t in tabs for w in t)
        lines: list[str] = []
        if matched:
            tab_ids = {t.id for t in tabs}
            for tm in boss.all_tab_managers:
                if any(t.id in tab_ids for t in tm):
                    lines.extend(tm.serialize_state_as_session(project.session_path, matched, ser_opts=opts, is_first=not lines))
        if not lines:
            # No live tabs belong to this project, do not overwrite a good
            # snapshot with an empty one.
            return False
        data = '\n'.join(lines).rstrip() + '\n'
        os.makedirs(os.path.dirname(project.session_path), exist_ok=True)
        atomic_save(data.encode('utf-8'), project.session_path)
        return True

    def save_all(self) -> None:
        from .fast_data_types import get_boss

        boss = get_boss()
        if boss is None:
            return
        loaded = set(boss.all_loaded_session_names)
        loaded |= {t.created_in_session_name for t in boss.all_tabs if t.created_in_session_name}
        if loaded:
            # Remember which projects are open for the next startup. Nothing is
            # loaded any more while ditty is being destroyed, keep the state
            # saved while quitting in that case.
            for p in self.projects:
                p.open_at_exit = p.session_name in loaded
        # A project stops closing once its tabs are gone, or when the user
        # cancelled closing some of them and then opened it again.
        self._closing = {sn for sn in self._closing if sn in loaded}
        for p in self.projects:
            if p.session_name in self._closing:
                continue
            if p.session_name in loaded:
                try:
                    self.save_project(p)
                except Exception as e:
                    log_error(f'Failed to save project {p.display_name}: {e}')
        self.save_index()

    def schedule_save(self) -> None:
        from .fast_data_types import add_timer, get_options

        opts = get_options()
        if not opts.sidebar_enabled or not opts.sidebar_autosave:
            return
        if self._save_timer is not None:
            return
        self._save_timer = add_timer(self._on_save_timer, max(0.2, opts.sidebar_autosave_delay), False)

    def _on_save_timer(self, timer_id: int | None = None) -> None:
        self._save_timer = None
        self.save_all()

    # }}}

    def _periodic_save(self, timer_id: int | None = None) -> None:
        self.save_all()

    def on_startup(self, boss: 'Boss') -> None:
        from .fast_data_types import get_options

        if not get_options().sidebar_enabled:
            return
        if native_sidebar_active():
            from .fast_data_types import sidebar_set_callback

            sidebar_set_callback(native_sidebar_action)
            if self.sidebar_width or self.sidebar_hidden:
                self.apply_sidebar_layout()
        tab = boss.active_tab
        if tab is None:
            return
        # Do not hijack tabs that were explicitly created from a session via
        # the command line.
        if tab.created_in_session_name:
            return
        if not self._restore_projects_at_startup(boss, tab):
            # First run: a fresh terminal belongs to a project for its
            # directory instead of an anonymous "Unfiled" bucket.
            w = tab.active_window
            cwd = (w.cwd_of_child if w is not None else None) or os.path.expanduser('~')
            p = self.new_project(cwd, activate=False)
            self.attach_tab(tab, p)
            p.expanded = True
            p.last_opened = time.time()
            self.save_project(p)
            self.save_index()
        self.schedule_save()
        if self._periodic_timer is None:
            from .fast_data_types import add_timer

            self._periodic_timer = add_timer(self._periodic_save, 60, True)
        self.redraw()

    def _restore_projects_at_startup(self, boss: 'Boss', startup_tab: 'Tab') -> bool:
        '''Like an IDE, re-open the projects that were open when ditty quit
        (or the most recently used one), from their saved sessions. The fresh
        startup tab is closed once something was restored. It must never be
        attached to a project and saved, as that would overwrite the saved
        session of the project with a single empty tab.'''
        if not self.projects:
            return False
        to_restore = sorted((p for p in self.projects if p.open_at_exit), key=lambda x: x.last_opened)
        if not to_restore:
            to_restore = [max(self.projects, key=lambda x: x.last_opened)]
        restored = False
        # Oldest first, so that the most recently used one ends up active
        for p in to_restore:
            try:
                restored = self.open_project(p) or restored
            except Exception as e:
                log_error(f'Failed to restore project {p.display_name}: {e}')
        if restored and any(t is not startup_tab for t in boss.all_tabs):
            boss.close_tab_no_confirm(startup_tab)
            return True
        return False

    # deletion/renaming {{{

    def delete_project(self, id_or_name: str, close_tabs: bool = True) -> bool:
        from .fast_data_types import get_boss

        p = self.find(id_or_name)
        if p is None:
            return False
        self.projects.remove(p)
        self.save_index()
        if close_tabs:
            boss = get_boss()
            if boss is not None:
                tabs = [t for t in boss.all_tabs if t.created_in_session_name == p.session_name]
                self._keep_os_windows_open(tabs)
                for tab in tabs:
                    boss.close_tab_no_confirm(tab)
        self.redraw()
        return True

    def rename_project(self, id_or_name: str, new_name: str) -> bool:
        p = self.find(id_or_name)
        if p is None or not new_name:
            return False
        p.name = new_name
        self.save_index()
        self.redraw()
        return True

    # }}}


_manager: ProjectManager | None = None


def get_project_manager() -> ProjectManager:
    global _manager
    if _manager is None:
        _manager = ProjectManager()
    return _manager
