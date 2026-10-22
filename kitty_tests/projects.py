#!/usr/bin/env python
# License: GPL v3 Copyright: 2026

import json
import os
from tempfile import TemporaryDirectory

from kitty.tab_bar import TabBarData

from .base import BaseTest


class TestProjects(BaseTest):
    def test_project_lifecycle_and_grouping(self):
        import kitty.projects as projects

        old = os.environ.get('DITTY_PROJECTS_DIR')
        try:
            with TemporaryDirectory() as tdir:
                os.environ['DITTY_PROJECTS_DIR'] = tdir
                projects._manager = None
                pm = projects.get_project_manager()
                self.ae(pm.projects, [])
                p = pm.new_project(tdir, 'Demo', activate=False)
                self.ae([x.name for x in pm.projects], ['Demo'])
                self.assertTrue(os.path.exists(p.session_path))
                with open(p.session_path) as f:
                    self.assertIn('launch --cwd=', f.read())
                self.assertTrue(os.path.exists(os.path.join(tdir, 'index.json')))
                with open(os.path.join(tdir, 'index.json')) as f:
                    data = json.load(f)
                self.ae(data['version'], 1)
                self.ae(data['projects'][0]['name'], 'Demo')

                # Grouping uses the session name attached to tabs
                groups = pm.sidebar_groups(
                    [
                        TabBarData('one', session_name=p.session_name),
                        TabBarData('two', session_name=p.session_name),
                        TabBarData('unfiled'),
                    ]
                )
                self.ae(len(groups), 2)
                self.ae(groups[0].project, p)
                self.ae([t.title for t in groups[0].tabs], ['one', 'two'])
                self.ae(groups[1].session_name, '')
                self.ae([t.title for t in groups[1].tabs], ['unfiled'])

                self.assertTrue(pm.rename_project(p.id, 'Renamed'))
                self.ae(pm.by_id(p.id).name, 'Renamed')

                # A fresh manager reads the index back
                projects._manager = None
                pm2 = projects.get_project_manager()
                self.ae([x.name for x in pm2.projects], ['Renamed'])
                self.assertTrue(pm2.delete_project(p.id, close_tabs=False))
                self.ae(pm2.projects, [])
        finally:
            projects._manager = None
            if old is None:
                os.environ.pop('DITTY_PROJECTS_DIR', None)
            else:
                os.environ['DITTY_PROJECTS_DIR'] = old
