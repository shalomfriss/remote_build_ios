# Provider-neutral companion

TCP/TLS + Bonjour bridge from the iOS ACP client to an ACP stdio agent.

Codex:

```bash
./companion/scripts/agent-phone
```

Remote access through ngrok (the bridge's TLS + PIN protection remains active):

```bash
./companion/scripts/agent-phone --ngrok
```

Paste the printed `tcp://...` endpoint into the app's Advanced host field and
paste the PIN normally. To keep the same public address between runs, reserve a
TCP address in ngrok and pass `--ngrok-url host:port` or set `GROK_NGROK_URL`.

Claude:

```bash
ACP_AGENT=claude ./companion/scripts/agent-phone
```

Local Ollama model through OpenCode:

```bash
ACP_AGENT=local ACP_MODEL=ollama/qwen3-coder:30b ./companion/scripts/agent-phone
```

Stub (tests only):

```bash
export GROK_COMPANION_INSECURE=1
python3 companion/scripts/acp_tcp_bridge.py --stub --no-tls --no-pair --host 127.0.0.1 --port 7391
```
