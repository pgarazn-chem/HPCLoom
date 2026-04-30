# HPCLoom — Autonomous Coding Agent for CPU-Only HPC Clusters

![HPCLoom](./HPCLoom.png)

An automated, self-correcting workflow for running AI coding agents ([Aider](https://github.com/Aider-AI/aider)) on CPU-only HPC clusters managed by **SGE (Sun Grid Engine)**, using [`llama.cpp`](https://github.com/ggerganov/llama.cpp) as the local inference backend.

The agent autonomously reads a task, writes Python code, executes and tests it, and iteratively fixes its own errors — all without human intervention.

---

## How It Works

```
qsub submit_job.sh
      │
      ▼
 llama-server starts (llama.cpp, CPU, OpenAI-compatible API)
      │  waits for /health → "ok"
      ▼
 Apptainer container (isolated Python env)
      │
      └─▶  run_loop.sh  (default: 20 iterations, set MAX_ITERATIONS in submit_job.sh)
                │
                ├─ Aider reads task from initial_prompt.txt
                ├─ LLM writes/edits Python code via SEARCH/REPLACE
                ├─ Python tests are executed
                ├─ On failure: traceback is fed back to LLM
                └─ On success: cowsay 🐄  →  exit 0
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| SGE cluster (`qsub`) | Tested on older HPC clusters |
| Apptainer | For isolated container execution |
| Internet access on login node | For model downloads and initial setup |
| ~24–72 GB RAM per node | Depends on model chosen (see table below) |

---

## Quick Start

### 1. Build the Environment

Run **once** from the login node. Downloads the Apptainer image, installs Aider and Python deps, and compiles the `llama-server` binary.

```bash
bash build_env.sh
```

### 2. Select and Download a Model

```bash
bash switch_model.sh qwen-3.6-35b   # recommended
# or
bash switch_model.sh -h              # list all options
```

This script:
- Downloads the GGUF file (with resume support)
- Patches `submit_job.sh` with the correct `--ctx-size` and model path
- Patches `run_loop.sh` with the correct model ID, edit format, context size, and output token limit

> [!TIP]
> **MoE models are strongly recommended on CPU-only clusters.** Models like Qwen3.6-35B (3.6B active params) and Gemma4-26B (4B active params) generate tokens much faster than dense models of equivalent quality, because only a fraction of weights are activated per forward pass.

### 3. Write Your Task

```bash
echo "Write a Python script using ASE to compute the adsorption energy of CO on Pt(111)..." \
  > workspace/initial_prompt.txt
```

Optionally, add read-only context files (API references, docs) for the agent:

```bash
mkdir -p workspace/docs
cp ase_api_reference.md workspace/docs/
```

### 4. Install Extra Python Packages (if needed)

If your task requires libraries not bundled in the container (e.g., `ase`, `pandas`), install them into the persistent `./libs` directory **before** submitting:

```bash
bash add_package.sh ase pandas numpy scipy
```

### 5. Submit the Job

```bash
qsub submit_job.sh
```

---

## Supported Models

The table below reflects the status of each model as tested in this workflow. **Validated** means the model successfully completed the autonomous coding loop end-to-end.

| Model key | Full name | Size (Q4_K_M) | Active params | Thinking | Validated | Notes |
|---|---|---|---|---|---|---|
| `qwen-3.6-35b` | Qwen3.6-35B-A3B | ~23 GB | 3.6B | ✅ | ✅ **Recommended** | Best balance: fast on CPU, strong instruction-following, agentic coding highlight in model card |
| `gemma-4-26b-moe` | Gemma 4 26B A4B | ~17 GB | 4B | ✅ | ✅ Validated | Excellent. Requires `--reasoning-format deepseek` at llama-server level for standard `<think>` tags |
| `qwen2.5-7b` | Qwen2.5-Coder-7B | ~4 GB | 7B (dense) | ❌ | ✅ Validated | Lightweight. Good for quick local tests. Limited reasoning |
| `devstral` | Devstral Small 2505 | ~13 GB | 24B (dense) | ❌ | ⏳ Not yet tested | Mistral's SWE-specialized agent. Expected to perform well — no thinking means less format confusion |
| `qwen3-30b` | Qwen3-30B-A3B-Instruct | ~18 GB | 3B | ✅ | ⏳ Not yet tested | Same family as qwen-3.6-35b. Expected strong performance |
| `deepseek-r1-qwen-32b` | DeepSeek-R1 Distill Qwen-32B | ~20 GB | 32B (dense) | ✅ | ⏳ Not yet tested | Pure reasoning distillation. Should handle structured formats well |
| `nemotron-nano-30b` | Nemotron-3-Nano-30B-A3B | ~15 GB | 3.6B | ✅ | ⚠️ Not recommended | Loops on Aider's strict `>>>>>>> REPLACE` format. Conflates reasoning tokens with edit blocks |
| `kimi-linear-48b` | Kimi-Linear-48B-A3B | ~25 GB | 3B | ❌ | ⚠️ Known issues | Documented loop problems with `diff` format. Use `whole` edit format as fallback |
| `mistral-small` | Mistral-Small-4-119B | ~65 GB | ~17B | ✅ | ⏳ Not yet tested | Requires ~96 GB RAM. Only feasible on high-memory nodes |

> [!NOTE]
> **Gemma 4 special setup**: Gemma 4 uses a non-standard thinking tag format internally. To make it compatible with Aider's `reasoning_tag: think`, start `llama-server` with `--reasoning-format deepseek`. This is already set correctly in `switch_model.sh` comments but must be added manually to `submit_job.sh` if you use this model.

> [!WARNING]
> **Nemotron and Kimi**: Both models are included in `switch_model.sh` for completeness, but have demonstrated reliability issues with Aider's structured edit formats in this workflow. Community benchmarks suggest their instruction-following for strict syntax is weaker than Qwen or Gemma models. If you use them, prefer `MODEL_EDIT_FORMAT="whole"` in `switch_model.sh`.

---

## Custom Model Support

Any GGUF model from Hugging Face can be used:

```bash
CUSTOM_MODEL_URL="https://huggingface.co/USER/REPO/resolve/main/model.gguf" \
CUSTOM_MODEL_NAME="my_model.gguf" \
CUSTOM_AIDER_ID="my-model" \
CUSTOM_MODEL_HAS_THINKING=true \
CUSTOM_CTX_SIZE=131072 \
CUSTOM_MAX_OUT=16384 \
CUSTOM_EDIT_FORMAT="diff" \
bash switch_model.sh custom
```

---

## Script Reference

### `switch_model.sh`
Central management script. Call it before every job to switch models. It:
- Downloads and validates the GGUF file (checks minimum expected byte size)
- Updates `MODEL_PATH` and `--ctx-size` in `submit_job.sh`
- Updates `AIDER_MODEL`, `MODEL_HAS_THINKING`, `MODEL_CTX_SIZE`, `MODEL_MAX_OUT`, and `MODEL_EDIT_FORMAT` in `run_loop.sh`

### `submit_job.sh`
SGE submission script. Key tunable parameters:

```bash
#$ -pe mp 12        # CPU cores (set to match your model's RAM needs)
#$ -l h_vmem=6G     # RAM per core (total = slots × vmem; e.g., 12 × 6G = 72 GB)
#$ -l h_rt=72:00:00 # Wall time limit
```

The server is started with the context size set by `switch_model.sh`. Ensure `h_vmem × slots` covers your model's file size plus KV-cache overhead (~1.5–2× model size at full context).

### `run_loop.sh`
Orchestration loop running inside the Apptainer container. Key behaviors:

- **Git checkpointing**: auto-commits before every Aider call so edits are always reversible
- **Thinking isolation**: generates `.aider.model.settings.yml` with `reasoning_tag: think` for models that support it, preventing internal reasoning from contaminating SEARCH/REPLACE blocks
- **Sampling parameters**: sets `temperature: 0.6` and `repetition_penalty: 1.05` to reduce repetition loops
- **FAIL reset**: unconditionally resets the `FAIL` flag at the start of each iteration (prevents false-positive failures propagating across iterations)
- **Error feedback**: on test failure, feeds the full traceback back to the LLM as the new task
- **Context re-injection**: on "no .py files created", re-injects the full `initial_prompt.txt` instead of a bare retry message

### `build_env.sh`
One-time setup. Builds the Apptainer SIF image, compiles `llama-server` from source, and installs Aider and base Python packages into `./libs`.

### `add_package.sh`
Installs additional Python packages into `./libs` for use inside the container. Run on the login node before submitting.

---

## Monitoring

| Log file | Contents |
|---|---|
| `logs/job_[ID].log` | Main SGE job output (server startup, loop status, exit code) |
| `workspace/aider_inference.log` | Full Aider chat/thinking history and iteration traces |
| `logs/llama_server_[ID].log` | Raw llama-server output (model loading, token stats) |
| `workspace/test_output.log` | stdout/stderr of the last Python test execution |

To watch a running job live:

```bash
tail -f workspace/aider_inference.log
```

---

## Tuning Guide

### Choosing the Right Edit Format

The `MODEL_EDIT_FORMAT` variable controls how Aider instructs the model to express code changes:

| Format | Best for | Risk |
|---|---|---|
| `diff` | Most models; uses `<<<<<<< SEARCH` / `>>>>>>> REPLACE` blocks | Model must output exact markers |
| `udiff` | Qwen3+ series; produces unified diff natively | Requires precise line numbers |
| `whole` | Fallback for models that struggle with structured formats | Larger token usage per edit |

### Context Window vs. RAM

A larger `--ctx-size` requires more KV-cache RAM. At Q4_K_M quantization:

| Context | Approximate extra RAM (30B model) |
|---|---|
| 32K | ~2 GB |
| 128K | ~8 GB |
| 262K | ~16 GB |
| 524K | ~32 GB |

For a 12-core × 6 GB = 72 GB node running a ~15 GB model, a safe context is **128K–262K**. Only use 524K if the node has ≥ 96 GB RAM.

---

## Credits and Acknowledgements

- **[Aider](https://github.com/Aider-AI/aider)** — AI coding assistant and file editing engine
- **[llama.cpp](https://github.com/ggerganov/llama.cpp)** — High-performance CPU inference backend
- **Model providers:**
  - [Qwen Team (Alibaba)](https://huggingface.co/Qwen) — Qwen3 and Qwen2.5-Coder series
  - [Google DeepMind](https://huggingface.co/google) — Gemma 4 series
  - [Mistral AI](https://huggingface.co/mistralai) — Mistral-Small and Devstral
  - [DeepSeek AI](https://huggingface.co/deepseek-ai) — DeepSeek-R1 reasoning series
  - [NVIDIA](https://huggingface.co/nvidia) — Nemotron series
  - [Moonshot AI](https://huggingface.co/MoonshotAI) — Kimi-Linear series
  - [Unsloth](https://huggingface.co/unsloth) and [Bartowski](https://huggingface.co/bartowski) — GGUF quantizations

---

## License

MIT License. See [LICENSE](LICENSE) for details. Provided "as is" without warranty.
