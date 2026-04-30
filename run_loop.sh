#!/bin/bash
# run_loop.sh
set -e

echo "=== Loading pre-installed dependencies ==="
export HOME=/workspace
export PYTHONUNBUFFERED=1

export PYTHONPATH=/libs:$PYTHONPATH
export PATH=/libs/bin:$PATH

if [ ! -d ".git" ]; then
    echo "=== Initializing Local Git Repository ==="
    git init
    git config --local user.email "agent@hpc.local"
    git config --local user.name "HPC AI Agent"
    git add -A
    git commit -m "Initial workspace state" --allow-empty
fi

# --- Fresh Start vs Resume ---
# FRESH_START=true  (default): clears all Aider session state and previously
#   generated output files before starting. Use when changing the task or model.
# FRESH_START=false: keeps existing files and state. Use to continue an
#   interrupted job from the last completed iteration.
FRESH_START="${FRESH_START:-true}"
if [ "$FRESH_START" = "true" ]; then
    echo "=== Fresh Start: clearing Aider session state and generated files ==="
    # Remove Aider session files (history, input log, tag cache)
    rm -f  /workspace/.aider.chat.history.md \
           /workspace/.aider.input.history
    rm -rf /workspace/.aider.tags.cache.v4 \
           /workspace/.aider/
    # Remove generated Python/shell source files (but keep run_loop.sh and initial_prompt.txt)
    find /workspace -maxdepth 1 -type f -name "*.py" -delete 2>/dev/null || true
    find /workspace -maxdepth 1 -type f -name "*.sh" \
        -not -name "run_loop.sh" -delete 2>/dev/null || true
    # Remove known generated binary/output files that are safe to regenerate
    find /workspace -maxdepth 2 -type f \( \
        -name "*.traj" -o -name "*.db"  -o -name "*.png"  \
        -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.gif" \
        -o -name "*.pdf" -o -name "*.npz" -o -name "*.npy"  \
        -o -name "*.h5"  -o -name "*.hdf5" \
        -o -name "test_output.log" \
    \) -delete 2>/dev/null || true
    echo "Fresh start complete."
else
    echo "=== Resume mode: keeping existing workspace state ==="
fi

echo "=== Reading task from initial_prompt.txt ==="
if [ ! -f "/workspace/initial_prompt.txt" ]; then
    echo "Error: /workspace/initial_prompt.txt not found!"
    exit 1
fi
TASK="$(cat /workspace/initial_prompt.txt)"
echo "Task: $TASK"

export OPENAI_API_BASE="http://localhost:11434/v1"
export OPENAI_API_KEY="llama"
export LITELLM_REQUEST_TIMEOUT=7200
export AIDER_API_TIMEOUT=7200

# --- Configuracion del modelo LLM (actualizada automaticamente por switch_model.sh) ---
AIDER_MODEL="openai/qwen-3.6-35b"
MODEL_HAS_THINKING=true
MODEL_CTX_SIZE=262144
MODEL_MAX_OUT=16384
MODEL_TEMPERATURE=0.6
# Formato de edicion: 'diff' (SEARCH/REPLACE), 'udiff' (unified diff), 'whole' (fallback).
MODEL_EDIT_FORMAT="udiff"

AIDER_LOG="/workspace/aider_inference.log"
echo "=== Beginning Iterative Agent Loop ===" > $AIDER_LOG

# --- Inicializacion del modo thinking (si el modelo lo soporta) ---
AIDER_EXTRA_FLAGS=""
AIDER_MODEL_SETTINGS="/workspace/.aider.model.settings.yml"

if [ "$MODEL_HAS_THINKING" = "true" ]; then
    # Generates .aider.model.settings.yml for Aider.
    # CONFIRMED VALID top-level ModelSettings fields in Aider v0.86.2 (from models.py):
    #   name, edit_format, weak_model_name, use_repo_map, send_undo_reply, lazy,
    #   overeager, reminder, examples_as_sys_msg, extra_params, cache_control,
    #   caches_by_default, use_system_prompt, use_temperature, streaming,
    #   editor_model_name, editor_edit_format, reasoning_tag, remove_reasoning,
    #   system_prompt_prefix, accepts_settings
    # INVALID keys (cause silent full-file rejection, disabling reasoning_tag):
    #   context_window, max_tokens  <-- NOT fields of ModelSettings dataclass!
    # Token limits go ONLY inside extra_params (API params) and metadata.json.
    cat > "$AIDER_MODEL_SETTINGS" << SETTINGS_EOF
- name: $AIDER_MODEL
  reasoning_tag: think
  extra_params:
    max_tokens: $MODEL_MAX_OUT
    timeout: 7200
    temperature: $MODEL_TEMPERATURE
    repetition_penalty: 1.05
SETTINGS_EOF
    AIDER_EXTRA_FLAGS="--model-settings-file $AIDER_MODEL_SETTINGS"
    echo "[Thinking] Modo thinking activo: bloques <think>...</think> seran aislados por Aider." | tee -a $AIDER_LOG
else
    # For models without thinking: same rules apply — no context_window/max_tokens
    # at top-level. Token limits go in extra_params and metadata.json only.
    cat > "$AIDER_MODEL_SETTINGS" << SETTINGS_EOF
- name: $AIDER_MODEL
  extra_params:
    max_tokens: $MODEL_MAX_OUT
    timeout: 7200
    temperature: $MODEL_TEMPERATURE
    repetition_penalty: 1.05
SETTINGS_EOF
    AIDER_EXTRA_FLAGS="--model-settings-file $AIDER_MODEL_SETTINGS"
    echo "[Thinking] Modo thinking desactivado para este modelo." | tee -a $AIDER_LOG
fi

# --- Register model context window via metadata file (complementary mechanism) ---
# .aider.model.metadata.json tells LiteLLM/the API layer about the model's token
# limits (used for request validation). This complements the top-level YAML keys
# context_window and max_tokens above, which control Aider's internal prompt-budget
# and repo-map sizing. Both are needed for correct operation.
AIDER_MODEL_METADATA="/workspace/.aider.model.metadata.json"
cat > "$AIDER_MODEL_METADATA" << METADATA_EOF
{
  "$AIDER_MODEL": {
    "max_tokens": $MODEL_MAX_OUT,
    "max_input_tokens": $MODEL_CTX_SIZE,
    "max_output_tokens": $MODEL_MAX_OUT,
    "litellm_provider": "openai",
    "mode": "chat"
  }
}
METADATA_EOF
AIDER_EXTRA_FLAGS="$AIDER_EXTRA_FLAGS --model-metadata-file $AIDER_MODEL_METADATA"
echo "[Metadata] Context window registered: input=$MODEL_CTX_SIZE tokens, output=$MODEL_MAX_OUT tokens." | tee -a $AIDER_LOG

# Maximum number of Aider→test iterations before giving up.
# Override at submission time without editing this file:
#   MAX_ITERATIONS=5 qsub submit_job.sh
MAX_ITERATIONS="${MAX_ITERATIONS:-20}"
ITER=1

while [ $ITER -le $MAX_ITERATIONS ]; do
    FAIL=""  # Reset incondicional al inicio de cada iteracion.
             # CRITICO: sin esto, un fallo previo bloquea todas las iteraciones siguientes
             # incluso si el LLM produce codigo correcto.
    echo "" | tee -a $AIDER_LOG
    echo "=== Iteration $ITER / $MAX_ITERATIONS ===" | tee -a $AIDER_LOG
    
    echo "Workspace contents:" | tee -a $AIDER_LOG
    ls -lA /workspace | tee -a $AIDER_LOG

    # Automatically track any manually added Markdown or textual context files before the loop
    git add -A || true
    git commit -m "Auto-checkpoint iteration $ITER" --allow-empty || true

    # Gather files to edit: exclude run_loop.sh (internal orchestration script) and logs
    FILES_TO_EDIT=()
    while IFS= read -r file; do
        if [ -n "$file" ]; then
            FILES_TO_EDIT+=("$file")
        fi
    done < <(find /workspace -maxdepth 1 -type f \
        -not -name "*.log"  -not -name "initial_prompt.txt" \
        -not -name "run_loop.sh" -not -name ".*" \
        -not -name "*.traj" -not -name "*.db"   -not -name "*.png"  \
        -not -name "*.jpg"  -not -name "*.jpeg" -not -name "*.gif"  \
        -not -name "*.pdf"  -not -name "*.npz"  -not -name "*.npy"  \
        -not -name "*.h5"   -not -name "*.hdf5" -not -name "*.sif"  \
        -not -name "*.zip"  -not -name "*.tar"  -not -name "*.gz"   \
        -not -name "*.pkl"  -not -name "*.pickle")

    # Gather read-only context files (e.g. documentation, API references) to help Aider
    READ_FLAGS=()
    if [ -d "/workspace/docs" ]; then
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                READ_FLAGS+=("--read" "$file")
            fi
        done < <(find /workspace/docs -type f)
    fi

    # 1. Ejecutar Aider
    # --edit-format $MODEL_EDIT_FORMAT: 'diff' (SEARCH/REPLACE) es el valor por defecto
    # para modelos locales cuantizados. Es mas tolerante a errores que 'udiff' (unified diff),
    # que requiere numeros de linea precisos. El valor viene de MODEL_EDIT_FORMAT en switch_model.sh.
    # --no-auto-commits: evita que Aider haga sus propios commits que interfieren
    # con los checkpoints del bucle.
    echo "Prompting LLM with the task and files... [edit-format: $MODEL_EDIT_FORMAT]" | tee -a $AIDER_LOG
    python -m aider.main --model "$AIDER_MODEL" --yes $AIDER_EXTRA_FLAGS \
        --edit-format "$MODEL_EDIT_FORMAT" \
        --no-auto-commits \
        --chat-history-file /dev/null \
        "${READ_FLAGS[@]}" \
        --message "$TASK" "${FILES_TO_EDIT[@]}" 2>&1 | tee -a $AIDER_LOG
    
    echo "Aider applied changes. Now running validation..." | tee -a $AIDER_LOG

    # --- 2. Detect and run the appropriate test/validation strategy ---
    #
    # Priority order:
    #   a) Python unittest suite (test_*.py)  → standard unit tests
    #   b) Python main script (non-test *.py) → run-to-completion check
    #   c) Bash script (*.sh, not run_loop.sh) → execute and check exit code
    #   d) Nothing runnable yet             → tell the LLM to create files

    TEST_PY=$(find /workspace -maxdepth 1 -name "test_*.py" | head -n 1)
    MAIN_PY=$(find /workspace -maxdepth 1 -name "*.py" -not -name "test_*.py" | sort | head -n 1)
    MAIN_SH=$(find /workspace -maxdepth 1 -name "*.sh" -not -name "run_loop.sh" | sort | head -n 1)

    if [ -n "$TEST_PY" ] || [ -n "$MAIN_PY" ]; then
        # --- Python path ---
        if python -m unittest discover -s /workspace -p "*.py" > /workspace/test_output.log 2>&1; then
            TEST_OUT=$(cat /workspace/test_output.log)
            if echo "$TEST_OUT" | grep -q "Ran 0 tests"; then
                # No unittest class found — run the main script directly
                if [ -n "$MAIN_PY" ]; then
                    python "$MAIN_PY" > /workspace/test_output.log 2>&1 || FAIL=1
                fi
            fi
        else
            FAIL=1
        fi

        if [ -z "$FAIL" ]; then
            echo "Validation passed!" | tee -a $AIDER_LOG
            python -c "import sys; sys.path.append('/libs'); import cowsay; cowsay.cow('Moo! Task complete in $ITER iterations and validated on HPC!')" | tee -a $AIDER_LOG
            exit 0
        else
            echo "Execution failed. Feeding traceback into LLM." | tee -a $AIDER_LOG
            # Truncate traceback to avoid overflowing the model context on repeated failures
            TRACEBACK="$(cat /workspace/test_output.log | head -c 3000)"
            TASK="The script failed when executed. Traceback (truncated to 3000 chars):\n${TRACEBACK}\nPlease fix the code."
        fi

    elif [ -n "$MAIN_SH" ]; then
        # --- Bash script path ---
        if bash "$MAIN_SH" > /workspace/test_output.log 2>&1; then
            echo "Bash script passed!" | tee -a $AIDER_LOG
            python -c "import sys; sys.path.append('/libs'); import cowsay; cowsay.cow('Moo! Task complete in $ITER iterations and validated on HPC!')" | tee -a $AIDER_LOG
            exit 0
        else
            echo "Bash script failed. Feeding output into LLM." | tee -a $AIDER_LOG
            TASK="The script failed when executed:\n$(cat /workspace/test_output.log)\nPlease fix the code."
        fi

    else
        # --- Nothing runnable yet ---
        echo "No runnable files found yet. Notifying LLM." | tee -a $AIDER_LOG
        ORIGINAL_TASK="$(cat /workspace/initial_prompt.txt)"
        TASK="No runnable files were created in the previous attempt. Please implement all required files now. Do NOT ask for clarification — write the code directly using SEARCH/REPLACE blocks.\n\nOriginal task:\n${ORIGINAL_TASK}"
    fi

    ITER=$((ITER + 1))
done

echo "Maximum iterations ($MAX_ITERATIONS) reached without passing validation. Terminating for manual inspection." | tee -a $AIDER_LOG
exit 1
