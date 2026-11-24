import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from photo_search import chatgpt_auth as auth
from photo_search.chatgpt_client import ChatGPTClient, response_text
from photo_search.providers import ModelProvider


class AuthTests(unittest.TestCase):
    def test_callback_rejects_csrf_duplicates_missing_or_changed_client(self):
        for path in ['/auth/callback?state=wrong&code=x&client_id=oaiapp_a',
                     '/auth/callback?state=right&state=right&code=x&client_id=oaiapp_a',
                     '/auth/callback?state=right&code=x',
                     '/auth/callback?state=right&code=x&client_id=dynamic_agent_client',
                     '/callback?state=right&code=x&client_id=oaiapp_a']:
            with self.subTest(path=path), self.assertRaises(auth.ChatGPTError):
                auth.callback_values(path, 'right')
        with self.assertRaises(auth.ChatGPTError):
            auth.callback_values('/auth/callback?state=right&code=x&client_id=other', 'right', 'saved')
        self.assertEqual(auth.callback_values('/auth/callback?state=right&code=x', 'right', 'saved'), ('saved', 'x'))

    def test_pkce_and_returning_registration(self):
        p = auth.authorize_parameters('host', 'http://127.0.0.1:12/auth/callback', 's', 'n', 'verifier')
        self.assertEqual(p['client_id'], 'dynamic_agent_client')
        self.assertIn(auth.PLAN_SCOPE, p['scope'])
        self.assertEqual(len(p['code_challenge']), 43)
        p = auth.authorize_parameters('host', 'uri', 's', 'n', 'v', {'client_id': 'saved', 'id_token': 'hint'})
        self.assertEqual(p['client_id'], 'saved')
        self.assertNotIn('agent_name_hint', p)

    def test_signature_audience_nonce_expiry_and_subject_are_verified(self):
        try:
            import jwt
            from cryptography.hazmat.primitives.asymmetric import rsa
        except ImportError:
            self.skipTest('Install backend[chatgpt] for signature verification tests')
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
        jwk['kid'] = 'fixture'
        claims = {'iss': auth.ISSUER, 'aud': 'client', 'sub': 'subject', 'nonce': 'nonce',
                  'iat': int(time.time()), 'exp': int(time.time()) + 600}
        def request(url):
            if url.endswith('openid-configuration'):
                return {'issuer': auth.ISSUER, 'jwks_uri': auth.ISSUER + '/.well-known/jwks.json'}
            return {'keys': [jwk]}
        with patch.object(auth, 'request_json', side_effect=request):
            token = jwt.encode(claims, key, algorithm='RS256', headers={'kid': 'fixture'})
            self.assertEqual(auth.validate_identity(token, 'client', nonce='nonce')['sub'], 'subject')
            for kwargs in [{'client_id':'other', 'nonce':'nonce'}, {'client_id':'client', 'nonce':'wrong'},
                           {'client_id':'client', 'subject':'other'}]:
                with self.assertRaises(auth.ChatGPTError):
                    auth.validate_identity(token, **kwargs)
            expired = jwt.encode({**claims, 'exp': int(time.time()) - 60}, key, algorithm='RS256', headers={'kid':'fixture'})
            with self.assertRaises(auth.ChatGPTError):
                auth.validate_identity(expired, 'client', nonce='nonce')

    def test_protected_storage_refresh_and_account_isolation(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(auth, 'AUTH_DIR', Path(directory)/'auth'):
            with auth.storage_lock():
                store = auth.read_store()
                store['accounts'] = {'a': {'subject':'sub-a', 'client_id':'a', 'scopes':[auth.PLAN_SCOPE],
                    'access_token':'old', 'refresh_token':'refresh', 'expires_at':0},
                    'b': {'subject':'sub-b', 'client_id':'b', 'scopes':[auth.PLAN_SCOPE],
                    'access_token':'other', 'expires_at':time.time()+600}}
                auth.write_store(store)
            with patch.object(auth, 'request_json', return_value={'access_token':'new', 'refresh_token':'rotated',
                        'token_type':'Bearer', 'expires_in':3600}) as request:
                self.assertEqual(auth.access_token('a'), 'new')
                self.assertEqual(auth.access_token('a'), 'new')
                self.assertEqual(request.call_count, 1)
                self.assertEqual(auth.access_token('b'), 'other')
            self.assertEqual((auth.AUTH_DIR/'accounts.json').stat().st_mode & 0o777, 0o600)
            self.assertEqual(auth.AUTH_DIR.stat().st_mode & 0o777, 0o700)
            self.assertNotIn('access_token', json.dumps(auth.status()))
            self.assertEqual(auth.read_store()['accounts']['a']['refresh_token'], 'rotated')

    def test_identity_only_grant_cannot_infer_or_use_api_key(self):
        p=ModelProvider('test','test','chatgpt',auth.RESOURCE,'m','test',chatgpt_account_id='a')
        with patch.dict(os.environ, {'PHOTO_SEARCH_API_KEY':'paid-secret'}):
            self.assertEqual(p.api_key, '')
        with tempfile.TemporaryDirectory() as d, patch.object(auth,'AUTH_DIR',Path(d)/'auth'):
            with auth.storage_lock():
                auth.write_store({'accounts':{'a':{'subject':'a','access_token':'x','scopes':['openid']}}})
            with self.assertRaises(auth.ChatGPTError):auth.access_token('a')
        with self.assertRaises(auth.ChatGPTError):
            ChatGPTClient(ModelProvider('test','test','chatgpt','https://other.example','m','test',chatgpt_account_id='a'))


class StreamTests(unittest.TestCase):
    def test_remote_preference_wins_and_only_explicit_chatgpt_fallback_is_probed(self):
        from photo_search.providers import default_provider
        from photo_search.worker import select_processing_provider
        from photo_search.qwen import ModelProviderError
        primary=default_provider()
        fallback=ModelProvider('chatgpt-plan','ChatGPT','chatgpt',auth.RESOURCE,'m','chatgpt-plan',chatgpt_account_id='a')
        state={}
        with patch('photo_search.worker.write_worker_status'), patch('photo_search.worker._confirm_model_reachable') as probe:
            self.assertEqual(select_processing_provider(primary,fallback,state),primary)
            self.assertEqual(probe.call_count,1)
            probe.reset_mock();probe.side_effect=[ModelProviderError('offline'),None]
            self.assertEqual(select_processing_provider(primary,fallback,state),fallback)
            self.assertEqual(probe.call_args.args[0],fallback)
            probe.reset_mock();probe.side_effect=None
            self.assertEqual(select_processing_provider(primary,fallback,state),primary)
            self.assertNotIn('fallback_reason',state)

    def test_quota_errors_pause_instead_of_marking_images_skipped(self):
        from photo_search.qwen import QwenClient, ModelProviderError
        from photo_search.indexer import is_transient_error
        p=ModelProvider('test','test','chatgpt',auth.RESOURCE,'m','test',chatgpt_account_id='a')
        with patch('photo_search.chatgpt_client.ChatGPTClient.complete',side_effect=auth.ChatGPTError('subscription_sharing_usage_limit_exceeded')):
            with self.assertRaises(ModelProviderError) as result:QwenClient(p)._annotate_content([], 'prompt')
        self.assertTrue(is_transient_error(result.exception))

    def stream(self, *events):
        return io.BytesIO(b''.join(b'data: '+json.dumps(e).encode()+b'\n\n' for e in events))

    def test_completion_is_required_and_late_usage_failure_is_not_success(self):
        delta={'type':'response.output_text.delta','delta':'partial result'}
        for events in [(delta,), (delta,{'type':'response.failed','response':{'error':{'code':'subscription_sharing_usage_limit_exceeded'}}}),
                       ({'type':'response.incomplete','response':{}},)]:
            with self.assertRaises(auth.ChatGPTError):response_text(self.stream(*events))
        result={'type':'response.completed','response':{'status':'completed','output':[
            {'type':'message','content':[{'type':'output_text','text':'{"color":"red"}'}]}], 'usage':{'input_tokens':42}}}
        text, usage=response_text(self.stream(delta,result))
        self.assertEqual(json.loads(text)['color'],'red')
        self.assertEqual(usage['input_tokens'],42)

    def test_completed_plan_envelope_may_omit_output_but_partial_stream_is_rejected(self):
        delta={'type':'response.output_text.delta','output_index':0,'content_index':0,'delta':'{"color":"red"}'}
        done={'type':'response.output_text.done','output_index':0,'content_index':0,'text':'{"color":"red"}'}
        completed={'type':'response.completed','response':{'status':'completed','output':[],
                   'usage':{'input_tokens':20,'output_tokens':8,'attribution':{'private':'omitted'}}}}
        text,usage=response_text(self.stream(delta,done,completed))
        self.assertEqual(json.loads(text)['color'],'red')
        self.assertNotIn('attribution',usage)
        with self.assertRaises(auth.ChatGPTError):response_text(self.stream(delta,done))

    def test_plan_request_uses_responses_without_unsupported_parameters(self):
        p=ModelProvider('test','test','chatgpt',auth.RESOURCE,'m','test',chatgpt_account_id='a')
        event={'type':'response.completed','response':{'status':'completed','output':[
            {'type':'message','content':[{'type':'output_text','text':'{}'}]}]}}
        with patch('photo_search.chatgpt_client.access_token',return_value='grant'), \
             patch('photo_search.chatgpt_client.open_request',return_value=self.stream(event)) as opened:
            ChatGPTClient(p).complete('instructions',[{'type':'image_url','image_url':{'url':'data:image/png;base64,fixture'}}])
            req=opened.call_args.args[0];body=json.loads(req.data)
            self.assertEqual(req.full_url, auth.RESOURCE+'/responses')
            self.assertEqual(body['store'],False);self.assertTrue(body['stream'])
            self.assertEqual(body['input'][0]['content'][0]['type'],'input_image')
            self.assertNotIn('temperature',body);self.assertNotIn('max_output_tokens',body)


if __name__ == '__main__':unittest.main()
