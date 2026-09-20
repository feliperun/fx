# FX Jev capability-selection shadow Harbor Hub agent

This source package lets Harbor Hub stage the exact Linux binary for the Jev
capability-selection shadow experiment. It preserves the benchmarked
`fx ask --yolo --json` execution path; ACP is only the hosted transport
envelope.

- FX experiment source: branch `experiment/jev-capability`
- Binary SHA-256: `9e69cbd6c27936ae7911f0e126f05057f38b6605a9a82368e38b443199f84b51`
- Binary target: `x86_64-linux-musl`
- Optimization profile: `ReleaseSafe`
- Model: `vercel_ai_gateway/openai/gpt-5.6-sol`
- Effort: `xhigh`
- Logs: `/logs/agent/fx.json`, `/logs/agent/fx-stderr.log`, and
  `/logs/agent/fx-trace.log`

Use Harbor's direct credential mode with `AI_GATEWAY_API_KEY` and
`HOSTED_INFERENCE_URL=https://ai-gateway.vercel.sh`. The wrapper pins
`FX_EXPERIMENT_JEV_CAPABILITY_SHADOW=1` for every task, so each prompt produces
one `event=jev_capability_suggest` trace record in `/logs/agent/fx-trace.log`
without changing the turn.
