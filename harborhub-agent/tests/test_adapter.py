import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fx_jev_agent.evaluation import POLICY, evaluate
from fx_jev_agent.__main__ import selected_build, routing_trace
from unittest.mock import patch


class AdapterTests(unittest.TestCase):
    def test_preflight_requires_direct_credentials(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, 'credential_missing'):
                evaluate('preflight', {})

    def test_native_routing_trace_keeps_child_identity_and_malformed_events(self):
        data = {'policy':'jev-assignment-v2', 'origin':'subagent', 'decision':{'model':POLICY['defaultModel'], 'evaluated':True}}
        trace = '1 [quality] event=jev_route turn_id=7 subagent_id=3 data=' + json.dumps(data)
        routes, errors = routing_trace(trace + '\n2 event=jev_route turn_id=9 data=broken')
        self.assertEqual(errors, 1)
        self.assertEqual(routes[0]['turnId'], 7)
        self.assertEqual(routes[0]['subagentId'], 3)

    def test_binary_variant_rejects_wrong_experiment_switches(self):
        with patch.dict(os.environ, {'FX_BENCH_VARIANT':'patch-retry'}, clear=True):
            with self.assertRaisesRegex(ValueError, 'switches'):
                selected_build()
        with patch.dict(os.environ, {
            'FX_BENCH_VARIANT':'patch-retry', 'FX_EXPERIMENT_X9_EDITOR':'patch_v3',
            'FX_EXPERIMENT_X9_PROVIDER_RETRY':'adaptive_v1',
        }, clear=True):
            self.assertEqual(selected_build()['variant'], 'patch-retry')
        with patch.dict(os.environ, {'FX_BENCH_VARIANT':'main', 'FX_EXPERIMENT_JEV_COMPACTION':'1'}, clear=True):
            with self.assertRaisesRegex(ValueError, 'switches'):
                selected_build()

    def test_acp_initialization_over_stdio(self):
        request = {'jsonrpc':'2.0', 'id':1, 'method':'initialize', 'params':{'protocolVersion':1, 'clientCapabilities':{}}}
        result = subprocess.run([sys.executable, '-m', 'fx_jev_agent'], input=json.dumps(request)+'\n', text=True, capture_output=True, cwd=ROOT, timeout=10, env={**os.environ, 'PYTHONPATH':str(ROOT)})
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout.splitlines()[0])
        self.assertEqual(response['result']['agentInfo']['name'], 'fx-jev-matrix')
        self.assertNotIn('error', response)

    def test_native_variants_require_both_root_and_child_routing(self):
        for variant in ['routing', 'both']:
            switches = {'FX_BENCH_VARIANT':variant, 'FX_EXPERIMENT_JEV_ROUTING':'1',
                        'FX_EXPERIMENT_JEV_SUBAGENT_ROUTING':'1',
                        'FX_EXPERIMENT_JEV_COMPACTION':str(int(variant == 'both'))}
            with patch.dict(os.environ, switches, clear=True):
                self.assertEqual(selected_build()['variant'], variant)
            with patch.dict(os.environ, {**switches, 'FX_EXPERIMENT_JEV_SUBAGENT_ROUTING':'0'}, clear=True):
                with self.assertRaisesRegex(ValueError, 'switches'):
                    selected_build()

    def test_routing_v2_requires_typesafe_transport_and_rejects_gateway_key(self):
        base = {'FX_BENCH_VARIANT':'routing-v2', 'FX_EXPERIMENT_JEV_ROUTING':'1',
                'FX_EXPERIMENT_JEV_SUBAGENT_ROUTING':'1', 'FX_EXPERIMENT_JEV_COMPACTION':'0'}
        with patch.dict(os.environ, base, clear=True):
            with self.assertRaisesRegex(ValueError, 'typesafe_transport'):
                selected_build()
        with patch.dict(os.environ, {**base, 'FX_JEV_TRANSPORT':'typesafe'}, clear=True):
            build = selected_build()
            self.assertEqual(build['variant'], 'routing-v2')
            self.assertEqual(build['evaluationTransport'], 'typesafe')
        with patch.dict(os.environ, {**base, 'FX_JEV_TRANSPORT':'typesafe', 'FX_JEV_GATEWAY_API_KEY':'x'}, clear=True):
            with self.assertRaisesRegex(ValueError, 'gateway_evaluation_key'):
                selected_build()

    def test_sol_fixed_pins_strong_model_without_routing(self):
        from fx_jev_agent.__main__ import requested_model
        with patch.dict(os.environ, {'FX_BENCH_VARIANT':'sol-fixed'}, clear=True):
            build = selected_build()
            self.assertEqual(build['variant'], 'sol-fixed')
            self.assertEqual(requested_model(build), 'vercel_ai_gateway/openai/gpt-5.6-sol')
        with patch.dict(os.environ, {'FX_BENCH_VARIANT':'sol-fixed', 'FX_EXPERIMENT_JEV_ROUTING':'1'}, clear=True):
            with self.assertRaisesRegex(ValueError, 'switches'):
                selected_build()


if __name__ == '__main__':
    unittest.main()
