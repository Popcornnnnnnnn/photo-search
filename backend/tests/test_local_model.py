import json
import subprocess
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from photo_search.local_model import ensure_local_model, uses_lm_studio
from photo_search.providers import ModelProvider, default_provider
from photo_search.worker import _confirm_model_reachable, select_processing_provider
from photo_search.qwen import ModelProviderError


class LocalModelTests(unittest.TestCase):
    def setUp(self):
        self.provider = ModelProvider('local', 'Local', 'local', 'http://127.0.0.1:1234/v1',
                                      'qwen3.8-27b-uncensored', 'test')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.calls = []
        self.loaded = False
        self.installed = [{'type': 'llm', 'modelKey': self.provider.model, 'vision': True}]

    def run_lms(self, command, **kwargs):
        args = command[1:]
        self.calls.append(args)
        output = ''
        if args[0] == 'ps':
            output = json.dumps([{'identifier': self.provider.model}] if self.loaded else [])
        if args[0] == 'ls':
            output = json.dumps(self.installed)
        if args[0] == 'load':
            self.loaded = True
        return subprocess.CompletedProcess(command, 0, output, '')

    def prepare(self):
        with patch('photo_search.local_model.APP_HOME', self.root), \
             patch('photo_search.local_model.ensure_app_dirs'), \
             patch('photo_search.local_model.Path.is_file', return_value=True), \
             patch('photo_search.local_model.subprocess.run', side_effect=self.run_lms):
            ensure_local_model(self.provider)

    def test_cold_server_loads_only_configured_installed_model_and_verifies(self):
        self.prepare()
        self.assertEqual(self.calls[0], ['server', 'start', '--port', '1234', '--bind', '127.0.0.1'])
        self.assertEqual([c[0] for c in self.calls], ['server', 'ps', 'ls', 'load', 'ps'])
        self.assertIn(self.provider.model, self.calls[3])
        self.assertNotIn('get', [c[0] for c in self.calls])
        self.assertNotIn('unload', [c[0] for c in self.calls])

    def test_already_loaded_does_not_reload(self):
        self.loaded = True
        self.prepare()
        self.assertEqual([c[0] for c in self.calls], ['server', 'ps'])

    def test_missing_model_fails_without_downloading_or_selecting_another(self):
        self.installed = [{'type': 'llm', 'modelKey': 'another-model', 'vision': True}]
        with self.assertRaisesRegex(RuntimeError, 'not installed'):
            self.prepare()
        self.assertEqual([c[0] for c in self.calls], ['server', 'ps', 'ls'])

    def test_text_only_model_is_rejected(self):
        self.installed[0]['vision'] = False
        with self.assertRaisesRegex(RuntimeError, 'does not support images'):
            self.prepare()

    def test_cloud_tunnel_and_other_servers_are_not_started(self):
        excluded = [default_provider(), replace(self.provider, kind='cloud'),
                    replace(self.provider, requires_tailscale=True)]
        excluded += [replace(self.provider, base_url=url) for url in [
            'http://remote.example:1234/v1', 'http://127.0.0.1:18000/v1',
            'https://127.0.0.1:1234/v1', 'http://127.0.0.1:1234/other']]
        with patch('photo_search.local_model.subprocess.run') as run:
            for provider in excluded:
                self.assertFalse(uses_lm_studio(provider))
                ensure_local_model(provider)
            run.assert_not_called()

    def test_cli_failure_and_timeout_are_reported(self):
        for error in [OSError('no service'), subprocess.TimeoutExpired('lms', 30)]:
            with self.subTest(error=error), \
                 patch('photo_search.local_model.APP_HOME', self.root), \
                 patch('photo_search.local_model.ensure_app_dirs'), \
                 patch('photo_search.local_model.Path.is_file', return_value=True), \
                 patch('photo_search.local_model.subprocess.run', side_effect=error):
                with self.assertRaisesRegex(RuntimeError, 'LM Studio server failed'):
                    ensure_local_model(self.provider)

    def test_probe_retries_transient_errors_and_rejects_missing_model(self):
        ready = {'data': [{'id': self.provider.model}]}
        with patch('photo_search.worker.QwenClient') as client:
            client.return_value.models.side_effect = [RuntimeError('timeout'), ready]
            _confirm_model_reachable(self.provider)
            self.assertEqual(client.return_value.models.call_count, 2)
        with patch('photo_search.worker.QwenClient') as client:
            client.return_value.models.return_value = {'data': [{'id': 'wrong-model'}]}
            with self.assertRaisesRegex(RuntimeError, 'does not offer'):
                _confirm_model_reachable(self.provider)
            self.assertEqual(client.return_value.models.call_count, 3)

    def test_preferred_remote_recovers_on_the_next_batch(self):
        preferred = default_provider()
        state = {}
        with patch('photo_search.worker.write_worker_status'), \
             patch('photo_search.worker._confirm_model_reachable') as probe:
            probe.side_effect = ModelProviderError('connection refused')
            self.assertEqual(select_processing_provider(preferred, self.provider, state), self.provider)
            self.assertIn('connection refused', state['fallback_reason'])
            probe.side_effect = None
            self.assertEqual(select_processing_provider(preferred, self.provider, state), preferred)
            self.assertNotIn('fallback_reason', state)
            self.assertEqual(state['requested_provider_id'], preferred.id)

    def test_manual_selection_does_not_probe_a_different_provider(self):
        with patch('photo_search.worker._confirm_model_reachable') as probe:
            self.assertEqual(select_processing_provider(self.provider, None, {}), self.provider)
            probe.assert_not_called()

    def test_fallback_cannot_send_photos_to_another_host(self):
        with self.assertRaisesRegex(ValueError, 'local LM Studio'):
            select_processing_provider(default_provider(), replace(self.provider, base_url='https://remote.invalid/v1'), {})

    def test_successful_cli_exit_must_actually_load_model(self):
        def no_load(command, **kwargs):
            result = self.run_lms(command, **kwargs)
            if command[1] == 'load':
                self.loaded = False
            return result
        with patch('photo_search.local_model.APP_HOME', self.root), \
             patch('photo_search.local_model.ensure_app_dirs'), \
             patch('photo_search.local_model.Path.is_file', return_value=True), \
             patch('photo_search.local_model.subprocess.run', side_effect=no_load):
            with self.assertRaisesRegex(RuntimeError, 'did not load'):
                ensure_local_model(self.provider)
