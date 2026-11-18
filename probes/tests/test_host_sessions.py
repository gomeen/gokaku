"""宿主编排回归：执行真实 main，用 fake 桌面复现跨宿主焦点抢占。"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

PROBES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROBES))
import first_key_regression as fkr

spec = importlib.util.spec_from_file_location('validate_real_hosts', PROBES / 'validate-real-hosts.py')
real_hosts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(real_hosts)


class MainLifecycleTests(unittest.TestCase):
    def run_main(self, module, *, fail_open=None, fail_stage=None, strict_only=False,
                 product_failure=False):
        events, active = [], set()
        front = None
        focused = False
        stages = []

        class Driver:
            temp = Path('/fake')
            ax_binary = temp / 'ax-reader'

            def build(self):
                events.append(('driver', 'build'))
                return {'pid': 1}

            def ask(self, **request):
                return {'source': fkr.SOURCE}

            def ax(self, **request):
                return {'ok': True, 'frontBundle': front, 'markerOk': True, 'pid': 1}

            def close(self):
                events.append(('driver', 'restore'))
                self_test.assertFalse(active)

        self_test = self

        class Session:
            guard_marker = ''
            guard_pid = 0

            def __init__(self, driver, host, target, run_id):
                self.driver = driver
                self.key = (host, target)
                self.guard_bundle = self.key
                self.name = host

            def open(self):
                nonlocal front
                active.add(self.key)
                front = self.key  # 第二个宿主打开后，第一宿主失焦。
                events.append((self.key, 'open'))
                if self.key == fail_open:
                    raise fkr.HostError('synthetic open failure')

            def focus_target(self):
                nonlocal front, focused
                front, focused = self.key, True
                events.append((self.key, 'focus'))

            def assert_front(self):
                if front != self.key:
                    raise fkr.GuardError('wrong front target')

            def close(self):
                events.append((self.key, 'close'))
                self_test.assertIn(self.key, active, '会话只能关闭一次')
                active.remove(self.key)

        def stage(session, name):
            nonlocal focused
            events.append((session.key, name))
            if front != session.key:
                raise fkr.GuardError('前台是后打开的宿主')
            self.assertEqual(active, {session.key}, '同一时间只能打开一个测试目标')
            self.assertTrue(focused, '每个阶段进入前必须重新聚焦')
            focused = False
            stages.append((session.key, name))
            if fail_stage == name:
                raise fkr.GuardError('synthetic target loss')

        class Runner:
            def __init__(self, driver, panel, iterations, **kwargs):
                self.groups, self.panel_reports, self.checks = [], [], []
                self.failures = 0
                self.letters_enabled = True
                self.iterations = iterations
                self_test.assertEqual(kwargs['warmup'], 3)

            def run_group(self, session, group):
                stage(session, 'group')
                self.groups.append(group)
                if product_failure:
                    self.failures += 1
                    self.checks.append({'check': group['id'], 'ok': False})

            def run_panel_check(self, session, confirm):
                stage(session, 'panel')
                self.panel_reports.append({'confirm': confirm['id']})

            def run_caret_probe(self, session, **kwargs):
                stage(session, 'caret')

        with tempfile.TemporaryDirectory() as temp, contextlib.ExitStack() as stack:
            report_path = Path(temp) / 'report.json'
            argv = ['host-test', '--hosts', 'probe,textedit,chrome', '--iterations', '2',
                    '--warmup', '3', '--no-panel-state', '--report', str(report_path)]
            if module is fkr:
                argv.append('--caret-probe')
            elif strict_only:
                argv.append('--no-first-key')
            for name, value in [('Driver', Driver), ('make_session', Session), ('Runner', Runner),
                                ('input_letters_enabled', lambda: True)]:
                stack.enter_context(patch.object(fkr, name, value))
            stack.enter_context(patch.object(fkr.time, 'sleep'))
            stack.enter_context(patch.object(real_hosts, 'run_scenarios',
                                             lambda session, *args: stage(session, 'strict')))
            stack.enter_context(patch.object(sys, 'argv', argv))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            result = module.main()
            report = json.loads(report_path.read_text()) if report_path.exists() else None
        self.assertEqual(events.count(('driver', 'build')), 1)
        self.assertEqual(events[-1], ('driver', 'restore'))
        self.assertFalse(active)
        return result, events, stages, report

    def test_both_mains_finish_each_target_before_opening_next(self):
        for module in (real_hosts, fkr):
            with self.subTest(main=module.__name__):
                result, events, stages, report = self.run_main(module)
                self.assertEqual(result, 0, events)
                keys = [('probe', 'default'), ('textedit', 'default'),
                        ('chrome', 'textarea'), ('chrome', 'contenteditable')]
                for key in keys:
                    self.assertEqual(events.count((key, 'close')), 1)
                for previous, following in zip(keys, keys[1:]):
                    self.assertLess(events.index((previous, 'close')), events.index((following, 'open')))
                matrix = report['firstKeyMatrix'] if module is real_hosts else report
                expected = fkr.build_plan(['probe', 'textedit', 'chrome'], 2)
                self.assertEqual(matrix['groups'], expected['groups'])
                self.assertEqual({k: v for k, v in matrix['plan'].items() if k != 'createdAt'},
                                 {k: v for k, v in expected.items() if k not in ('groups', 'createdAt')})
                self.assertEqual(len(matrix['panelReports']), len(keys) * len(fkr.CONFIRMATIONS))
                self.assertEqual(sum(name == 'caret' for _, name in stages), 4 if module is fkr else 0)

    def test_strict_only_still_serializes_sessions(self):
        result, _, stages, report = self.run_main(real_hosts, strict_only=True)
        self.assertEqual(result, 0)
        self.assertEqual([name for _, name in stages], ['strict'] * 4)
        self.assertIsNone(report['firstKeyMatrix'])

    def test_guard_failure_closes_current_target_and_stops_without_retry(self):
        for module in (real_hosts, fkr):
            names = ('strict', 'group', 'panel') if module is real_hosts else ('group', 'caret', 'panel')
            for name in names:
                with self.subTest(main=module.__name__, phase=name):
                    result, events, stages, _ = self.run_main(module, fail_stage=name)
                    self.assertEqual(result, 5)
                    self.assertEqual(sum(stage == name for _, stage in stages), 1)
                    self.assertTrue(all(key == ('probe', 'default') for key, _ in stages))
                    self.assertNotIn((('textedit', 'default'), 'open'), events)

    def test_product_failures_remain_in_report_without_retry(self):
        for module in (real_hosts, fkr):
            with self.subTest(main=module.__name__):
                result, _, stages, report = self.run_main(module, product_failure=True)
                self.assertEqual(result, 1)
                self.assertEqual(report['failures'], 80)
                self.assertEqual(len(report['checks']), 80)
                self.assertTrue(all(not check['ok'] for check in report['checks']))
                self.assertEqual(sum(name == 'group' for _, name in stages), 80)

    def test_partially_opened_session_is_closed_and_recorded_as_skipped(self):
        for module in (real_hosts, fkr):
            with self.subTest(main=module.__name__):
                result, _, stages, report = self.run_main(module, fail_open=('textedit', 'default'))
                self.assertEqual(result, 0)
                self.assertEqual(report['skipped'], [{'host': 'textedit', 'target': 'default',
                                                     'reason': 'synthetic open failure'}])
                self.assertFalse(any(key[0] == 'textedit' for key, _ in stages))


class AXSnapshotTests(unittest.TestCase):
    def test_each_request_observes_current_foreground_not_reader_startup_cache(self):
        import subprocess
        with tempfile.TemporaryDirectory() as temp:
            driver = fkr.Driver(workdir=temp)
            state = Path(temp) / 'front.json'
            state.write_text('{"frontBundle":"probe"}')
            # 模拟无 AppKit run loop 的读取器：进程启动时缓存前台身份。
            driver.ax_binary.write_text(
                f'#!{sys.executable}\nimport json,sys\nfrom pathlib import Path\n'
                f'cached=Path({str(state)!r}).read_text()\n'
                'for line in sys.stdin:\n'
                '    if json.loads(line).get("op") == "quit": break\n'
                '    print(cached, flush=True)\n')
            driver.ax_binary.chmod(0o700)
            driver.ax_proc = subprocess.Popen([str(driver.ax_binary), '--stdin'],
                                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(driver.ax(op='check', marker='run')['frontBundle'], 'probe')
                state.write_text('{"frontBundle":"textedit"}')
                self.assertEqual(driver.ax(op='check', marker='run')['frontBundle'], 'textedit')
            finally:
                driver.ax_proc.terminate()
                driver.ax_proc.wait(timeout=5)
                driver.ax_proc.stdin.close()
                driver.ax_proc.stdout.close()
                driver.close()


class BrowserFixtureServerTests(unittest.TestCase):
    @staticmethod
    def get(url, path=None):
        from http.client import HTTPConnection
        from urllib.parse import urlsplit
        parsed = urlsplit(url)
        connection = HTTPConnection(parsed.hostname, parsed.port, timeout=2)
        try:
            connection.request('GET', path or parsed.path + '?' + parsed.query)
            response = connection.getresponse()
            return response.status, response.read(), response.getheader('Content-Type')
        finally:
            connection.close()

    def test_both_browsers_serve_only_exact_fixture_and_close_listener(self):
        from urllib.parse import parse_qs, urlsplit
        for factory in (fkr.ChromeSession, fkr.SafariSession):
            with self.subTest(browser=factory.name):
                session = factory(unittest.mock.Mock(), 'fixture-run')
                try:
                    with patch.object(session, 'activate'), \
                            patch.object(session, 'assert_front', return_value={'pid': 123}), \
                            patch.object(fkr.time, 'sleep'):
                        url = session.open()['url']
                    parsed = urlsplit(url)
                    self.assertEqual(parsed.hostname, '127.0.0.1')
                    self.assertEqual(parsed.scheme, 'http')
                    self.assertEqual(parsed.path, '/host.html')
                    self.assertEqual(parse_qs(parsed.query), {'run': ['fixture-run']})
                    self.assertGreater(parsed.port, 0)
                    self.assertEqual(session.fixture_server.server_address, ('127.0.0.1', parsed.port))
                    status, body, content_type = self.get(url)
                    self.assertEqual(status, 200)
                    self.assertEqual(body, session.page.read_bytes())
                    self.assertEqual(content_type, 'text/html; charset=utf-8')
                    for path in ('/', '/favicon.ico', '/README.md', '/../README.md',
                                 '/%2e%2e/README.md', '/host.html/extra'):
                        self.assertEqual(self.get(url, path)[0], 404, path)
                    thread = session.fixture_thread
                finally:
                    session.close()
                self.assertFalse(thread.is_alive())
                self.assertIsNone(session.fixture_server)
                with self.assertRaises(OSError):
                    self.get(url)

    def test_navigation_failure_stops_server_before_open_raises(self):
        session = fkr.SafariSession(unittest.mock.Mock(), 'fixture-run')
        observed = {}

        def fail_navigation(url):
            observed.update(url=url, thread=session.fixture_thread)
            self.assertEqual(self.get(url)[0], 200)
            raise fkr.HostError('synthetic navigation failure')

        with patch.object(session, 'activate', side_effect=fail_navigation):
            with self.assertRaisesRegex(fkr.HostError, 'synthetic navigation failure'):
                session.open()
        self.assertFalse(observed['thread'].is_alive())
        with self.assertRaises(OSError):
            self.get(observed['url'])
        session.close()  # main 的 finally 可重复清理。

    def test_close_error_still_joins_server_thread(self):
        for factory in (fkr.ChromeSession, fkr.SafariSession):
            with self.subTest(browser=factory.name):
                session = factory(unittest.mock.Mock(), 'fixture-run')
                with patch.object(session, 'activate'), \
                        patch.object(session, 'assert_front', return_value={'pid': 123}), \
                        patch.object(fkr.time, 'sleep'):
                    url = session.open()['url']
                thread = session.fixture_thread
                if factory is fkr.ChromeSession:
                    session.proc = unittest.mock.Mock()
                    session.proc.terminate.side_effect = RuntimeError('close failed')
                else:
                    session.window_id = 123
                with patch.object(fkr, 'osa', side_effect=RuntimeError('close failed')):
                    with self.assertRaisesRegex(RuntimeError, 'close failed'):
                        session.close()
                self.assertFalse(thread.is_alive())
                with self.assertRaises(OSError):
                    self.get(url)
                # Chrome 的模拟进程没有真实资源，只清理测试所建 profile。
                if factory is fkr.ChromeSession:
                    session.proc = None
                    session.close()


class BrowserOwnershipTests(unittest.TestCase):
    def test_title_comes_from_guarded_front_ax_window(self):
        driver = unittest.mock.Mock()
        session = fkr.ChromeSession(driver, 'unique-run')
        session.guard_bundle = session.bundle
        session.guard_pid = 123
        session.guard_marker = 'unique-run'
        title = 'Gogaku Test unique-run {"area":"test","focus":"area"} - Google Chrome'
        driver.ax.return_value = {'ok': True, 'frontBundle': session.bundle,
                                 'axBundle': session.bundle, 'pid': 123,
                                 'markerOk': True, 'title': title}
        try:
            with patch.object(fkr, 'osa', side_effect=AssertionError('不能按 bundle 读取旧 Chrome')):
                self.assertEqual(session.page_state()['area'], 'test')
                for field, wrong in [('pid', 456), ('frontBundle', 'other'),
                                     ('axBundle', 'other'), ('markerOk', False)]:
                    with self.subTest(field=field):
                        old = driver.ax.return_value[field]
                        driver.ax.return_value[field] = wrong
                        with self.assertRaises(fkr.GuardError):
                            session.page_state()
                        driver.ax.return_value[field] = old
        finally:
            session.close()

    def test_focus_activates_owned_window_before_reading_or_sending(self):
        session = fkr.SafariSession(unittest.mock.Mock(), 'unique-run', target='contenteditable')
        events = []
        with patch.object(session, 'activate_window', side_effect=lambda: events.append('activate')), \
                patch.object(session, 'page_state', side_effect=lambda: events.append('read') or {'focus': 'rich'}), \
                patch.object(session, 'send') as send:
            self.assertTrue(session.focus_target())
        self.assertEqual(events, ['activate', 'read'])
        send.assert_not_called()

    def test_safari_owns_new_window_and_closes_only_its_id(self):
        session = fkr.SafariSession(unittest.mock.Mock(), 'unique-run')
        scripts = []

        def osa(script, **kwargs):
            scripts.append(script)
            return '701'

        with patch.object(fkr, 'osa', side_effect=osa), patch.object(fkr.time, 'sleep'), \
                patch.object(fkr.subprocess, 'check_call'):
            session.activate('file:///synthetic.html')
            session.close()
        self.assertIn('make new document', scripts[0])
        self.assertIn('candidateID is not in originalIDs', scripts[0])
        self.assertNotIn('return id of front window', scripts[0])
        self.assertEqual(session.window_id, 701)
        self.assertIn('701', scripts[-1])
        self.assertNotIn('repeat with', scripts[-1])
        self.assertNotIn('unique-run', scripts[-1])
        self.assertNotIn('close every', scripts[-1])

    def test_safari_partial_navigation_failure_still_closes_owned_id(self):
        session = fkr.SafariSession(unittest.mock.Mock(), 'unique-run')
        with patch.object(fkr, 'osa', side_effect=['702', fkr.HostError('navigation failed'), '']) as osa, \
                patch.object(fkr.time, 'sleep'), patch.object(fkr.subprocess, 'check_call'):
            with self.assertRaises(fkr.HostError):
                session.activate('file:///synthetic.html')
            session.close()
        self.assertIn('702', osa.call_args.args[0])

    def test_chrome_activation_and_cleanup_use_only_owned_process(self):
        session = fkr.ChromeSession(unittest.mock.Mock(), 'unique-run')
        session.proc = unittest.mock.Mock(pid=321)
        session.proc.poll.return_value = None
        with patch.object(fkr, 'osa') as osa, patch.object(fkr.time, 'sleep'):
            session.activate_window()
            session.close()
        self.assertIn('unix id is 321', osa.call_args.args[0])
        self.assertNotIn('tell application "Google Chrome"', osa.call_args.args[0])
        session.proc.terminate.assert_called_once()
        session.proc.kill.assert_not_called()

    def test_wrong_pid_aborts_before_any_key_is_sent(self):
        driver = unittest.mock.Mock()
        session = fkr.BaseSession(driver, 'unique-run')
        session.guard_bundle, session.guard_pid, session.guard_marker = 'browser', 123, 'unique-run'
        driver.ax.return_value = {'ok': True, 'frontBundle': 'browser', 'axBundle': 'browser',
                                 'pid': 456, 'title': 'unique-run', 'markerOk': True}
        with self.assertRaises(fkr.GuardError):
            session.send([[{'key': 'tab'}]])
        driver.ask.assert_not_called()

    def test_unopened_safari_does_not_close_any_window(self):
        session = fkr.SafariSession(unittest.mock.Mock(), 'unique-run')
        with patch.object(fkr, 'osa') as osa:
            session.close()
        osa.assert_not_called()


if __name__ == '__main__':
    unittest.main()
