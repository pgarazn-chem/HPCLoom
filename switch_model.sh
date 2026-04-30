#!/bin/bash
# switch_model.sh
# Descarga un modelo LLM en formato GGUF y actualiza los scripts de ejecución
# para que el workflow apunte al nuevo modelo.
#
# Uso:
#   bash switch_model.sh [MODELO]
#
# Modelos soportados (primer argumento):
#   qwen2.5-7b          -> Qwen2.5-Coder-7B-Instruct (por defecto, ligero, sin thinking, fmt: diff)
#   qwen-3.6-35b        -> Qwen3.6-35B MoE          (RECOMENDADO, CON thinking, ctx 262144, fmt: diff)
#   qwen3-30b           -> Qwen3-30B Instruct       (híbrido, CON thinking, ctx 262144, fmt: diff)
#   mistral-small       -> Mistral-Small-4 119B      (muy pesado, CON thinking, ctx 256000, fmt: diff)
#   gemma-4-26b-moe     -> Gemma 4 MoE (26B A4B)     (CON thinking*, ctx 256000, fmt: diff)
#                          *thinking tag no estandar: requiere --reasoning-format deepseek en llama.cpp
#   devstral            -> Devstral Small 2505       (SIN thinking, SWE-especializado, fmt: diff)
#   nemotron-nano-30b   -> Nemotron-Nano-30B         (CON thinking, ctx 524288, fmt: diff)
#   kimi-linear-48b     -> Kimi-Linear-48B MoE       (SIN thinking, ctx 524288, fmt: whole [fallback])
#   custom              -> Usar URL y nombre personalizados via variables de entorno:
#                          CUSTOM_MODEL_URL, CUSTOM_MODEL_NAME
#                          CUSTOM_AIDER_ID, CUSTOM_MODEL_HAS_THINKING, CUSTOM_CTX_SIZE
#
# Ejemplos:
#   bash switch_model.sh qwen-3.6-35b
#   bash switch_model.sh mistral-small
#   CUSTOM_MODEL_URL="https://..." CUSTOM_MODEL_NAME="mi.gguf" CUSTOM_MODEL_HAS_THINKING=true bash switch_model.sh custom

set -e

# ─── Mostrar ayuda ────────────────────────────────────────────────────────────
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "============================================================"
    echo "  switch_model.sh — Ayuda y Modelos Disponibles"
    echo "============================================================"
    echo ""
    echo "Uso:"
    echo "  bash switch_model.sh [MODELO]"
    echo ""
    echo "Modelos predefinidos:"
    echo "  qwen2.5-7b            -> Qwen2.5-Coder-7B         (~4 GB)  [por defecto]"
    echo "  qwen-3.6-35b          -> Qwen3.6-35B MoE          (~23 GB) [CON thinking]"
    echo "  deepseek-r1-qwen-32b  -> DeepSeek-R1 Distill 32B  (~20 GB) [CON thinking]"
    echo "  qwen3-30b             -> Qwen3-30B Instruct       (~18 GB) [CON thinking]"
    echo "  mistral-small         -> Mistral-Small-4 MoE      (~65 GB) [CON thinking]"
    echo "  gemma-4-26b-moe       -> Gemma 4 MoE (26B A4B)    (~17 GB) [CON thinking]"
    echo "  devstral              -> Devstral Small 2505      (~13 GB)"
    echo "  kimi-linear-48b       -> Kimi-Linear-48B MoE      (~25 GB) [Long Context]"
    echo "  nemotron-nano-30b     -> Nemotron-Nano-30B        (~15 GB)"
    echo "  custom                -> Usar configuracion personalizada."
    echo ""
    echo "Para agregar un modelo custom de forma aislada, define estas variables de entorno:"
    echo "  CUSTOM_MODEL_URL          -> (Requerido) URL .gguf del modelo a descargar"
    echo "  CUSTOM_MODEL_NAME         -> (Requerido) Nombre de archivo local para el modelo"
    echo "  CUSTOM_AIDER_ID           -> (Opcional) Identificador principal para Aider"
    echo "  CUSTOM_MODEL_HAS_THINKING -> (Opcional) 'true' o 'false'"
    echo "  CUSTOM_CTX_SIZE           -> (Opcional) Tamano maximo de contexto, ej. 16384"
    echo ""
    echo "Ejemplo de uso Custom:"
    echo "  CUSTOM_MODEL_URL='https://...' CUSTOM_MODEL_NAME='mi.gguf' bash switch_model.sh custom"
    echo "============================================================"
    exit 0
fi

# ─── Definicion de modelos ────────────────────────────────────────────────────
# Se usa if/elif en lugar de arrays asociativos para maxima compatibilidad.

SELECTED_MODEL="${1:-qwen2.5-7b}"

if [ "$SELECTED_MODEL" = "qwen2.5-7b" ]; then
    MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf"
    MODEL_NAME="qwen2.5-coder-7b-instruct-q4_k_m.gguf"
    AIDER_MODEL_ID="qwen2.5-coder"
    MODEL_NOTE="Modelo ligero. Sin thinking. Ideal para laptops estándar."
    MODEL_MIN_BYTES=4000000000
    MODEL_RAM_GB=8
    MODEL_HAS_THINKING=false
    MODEL_CTX_SIZE=131072
    MODEL_MAX_OUT=8192
    MODEL_TEMPERATURE=0.3   # lower temp for smaller model = less hallucination
    # 'diff': safe for small quantized models.
    MODEL_EDIT_FORMAT="diff"
    SERVER_EXTRA_FLAGS=""

elif [ "$SELECTED_MODEL" = "qwen-3.6-35b" ]; then
    MODEL_URL="https://huggingface.co/bartowski/Qwen_Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
    MODEL_NAME="Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
    AIDER_MODEL_ID="qwen-3.6-35b"
    MODEL_NOTE="Qwen 3.6 MoE (35B/A3B). CON thinking."
    MODEL_MIN_BYTES=21000000000
    MODEL_RAM_GB=32
    MODEL_HAS_THINKING=true
    MODEL_CTX_SIZE=262144
    MODEL_MAX_OUT=16384
    MODEL_TEMPERATURE=0.6   # Qwen official recommendation
    # 'udiff': VALIDATED in LLM_local_4 (11 cycles). Qwen3 generates unified diffs
    # natively. reasoning_tag:think in YAML strips <think>...</think> blocks so they
    # never contaminate the diff output.
    MODEL_EDIT_FORMAT="udiff"
    SERVER_EXTRA_FLAGS=""

elif [ "$SELECTED_MODEL" = "deepseek-r1-qwen-32b" ]; then
    MODEL_URL="https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
    MODEL_NAME="deepseek-r1-distill-qwen-32b-q4_k_m.gguf"
    AIDER_MODEL_ID="deepseek-r1"
    MODEL_NOTE="Reasoning model (CON thinking). DeepSeek-R1 distilled on Qwen-32B."
    MODEL_MIN_BYTES=18000000000
    MODEL_RAM_GB=32
    MODEL_HAS_THINKING=true
    MODEL_CTX_SIZE=131072
    MODEL_MAX_OUT=16384
    MODEL_TEMPERATURE=0.6   # DeepSeek-R1 recommended; 0 disables sampling variety
    # 'udiff': DeepSeek-R1 family emits unified diffs cleanly when reasoning is
    # stripped. reasoning_tag:think handles the <think>...</think> blocks.
    # Aider's own fireworks_ai/deepseek-r1 entry uses 'diff' but udiff is more
    # robust for local llama.cpp inference where streaming can fragment output.
    MODEL_EDIT_FORMAT="udiff"
    SERVER_EXTRA_FLAGS=""

elif [ "$SELECTED_MODEL" = "qwen3-30b" ]; then
    MODEL_URL="https://huggingface.co/bartowski/Qwen_Qwen3-30B-A3B-Instruct-2507-GGUF/resolve/main/Qwen_Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
    MODEL_NAME="Qwen_Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
    AIDER_MODEL_ID="qwen3-30b"
    MODEL_NOTE="Qwen3-30B MoE. Mismo family que qwen-3.6-35b. CON thinking."
    MODEL_MIN_BYTES=18000000000
    MODEL_RAM_GB=24
    MODEL_HAS_THINKING=true
    MODEL_CTX_SIZE=262144
    MODEL_MAX_OUT=16384
    MODEL_TEMPERATURE=0.6   # Qwen official recommendation
    # 'udiff': same Qwen3 family as qwen-3.6-35b. reasoning_tag:think handles
    MODEL_EDIT_FORMAT="udiff"
    SERVER_EXTRA_FLAGS=""

elif [ "$SELECTED_MODEL" = "mistral-small" ]; then
    MODEL_URL="https://huggingface.co/bartowski/mistralai_Mistral-Small-4-119B-2603-GGUF/resolve/main/mistralai_Mistral-Small-4-119B-2603-Q4_K_M.gguf"
    MODEL_NAME="mistralai_Mistral-Small-4-119b-q4_k_m.gguf"
    AIDER_MODEL_ID="mistral-small-4"
    MODEL_NOTE="MoE 119B (~65 GB). CON thinking. NOT validated in this workflow yet. Requires top-tier HPC node."
    MODEL_MIN_BYTES=60000000000
    MODEL_RAM_GB=96
    MODEL_HAS_THINKING=true
    MODEL_CTX_SIZE=256000
    MODEL_MAX_OUT=32768
    MODEL_TEMPERATURE=0.3   # conservative until validated
    # 'diff': Not yet validated in this workflow. Using conservative 'diff' (SEARCH/REPLACE)
    # until a successful run confirms udiff compatibility with this model.
    MODEL_EDIT_FORMAT="diff"
    SERVER_EXTRA_FLAGS=""

elif [ "$SELECTED_MODEL" = "gemma-4-26b-moe" ]; then
    MODEL_URL="https://huggingface.co/bartowski/google_gemma-4-26B-A4B-it-GGUF/resolve/main/google_gemma-4-26B-A4B-it-Q4_K_M.gguf"
    MODEL_NAME="google_gemma-4-26B-A4B-it-Q4_K_M.gguf"
    AIDER_MODEL_ID="gemma-4-26b-moe"
    MODEL_NOTE="Gemma4 MoE 26B/A4B (~16.8 GB). Apache 2.0. CON thinking — REQUIRES --reasoning-format deepseek in llama.cpp server."
    MODEL_MIN_BYTES=16000000000
    MODEL_RAM_GB=24
    MODEL_HAS_THINKING=true
    MODEL_CTX_SIZE=256000
    MODEL_MAX_OUT=16384
    MODEL_TEMPERATURE=0.6
    # IMPORTANT: Gemma4 uses a non-standard thinking tag (<|channel|>thought\n...<channel|>)
    # that Aider CANNOT parse. You MUST start llama.cpp with --reasoning-format deepseek
    # so the server rewraps thoughts in standard <think>...</think> tags.
    # reasoning_tag:think in the YAML then strips them correctly.
    # 'udiff': once llama.cpp rewraps the thinking, Gemma4 generates clean unified diffs.
    MODEL_EDIT_FORMAT="udiff"
    SERVER_EXTRA_FLAGS="--reasoning-format deepseek"

elif [ "$SELECTED_MODEL" = "devstral" ]; then
    MODEL_URL="https://huggingface.co/mistralai/Devstral-Small-2505-GGUF/resolve/main/Devstral-Small-2505-Q4_K_M.gguf"
    MODEL_NAME="devstral-small-2505-q4_k_m.gguf"
    AIDER_MODEL_ID="devstral"
    MODEL_NOTE="Agente SWE de Mistral. SIN thinking. Fine-tuned on SWE-Bench — strongest coding agent in its size class."
    MODEL_MIN_BYTES=13000000000
    MODEL_RAM_GB=16
    MODEL_HAS_THINKING=false
    MODEL_CTX_SIZE=128000
    MODEL_MAX_OUT=8192
    MODEL_TEMPERATURE=0.2   # deterministic preferred for SWE-focused model
    # 'diff': Devstral is SWE-fine-tuned (SEARCH/REPLACE). The model card recommends
    # diff-style edits. No thinking to interfere, so diff is safe and efficient.
    MODEL_EDIT_FORMAT="diff"
    SERVER_EXTRA_FLAGS=""

elif [ "$SELECTED_MODEL" = "kimi-linear-48b" ]; then
    MODEL_URL="https://huggingface.co/bartowski/moonshotai_Kimi-Linear-48B-A3B-Instruct-GGUF/resolve/main/moonshotai_Kimi-Linear-48B-A3B-Instruct-Q4_K_M.gguf"
    MODEL_NAME="moonshotai_Kimi-Linear-48B-A3B-Instruct-Q4_K_M.gguf"
    AIDER_MODEL_ID="kimi-linear-48b"
    MODEL_NOTE="Kimi MoE 48B/A3B. Long context (512k). WARNING: loops observed with diff in this workflow."
    MODEL_MIN_BYTES=22000000000
    MODEL_RAM_GB=80
    MODEL_HAS_THINKING=false
    MODEL_CTX_SIZE=524288
    MODEL_MAX_OUT=32768
    MODEL_TEMPERATURE=0.3
    # 'whole': Kimi-Linear showed severe looping with diff/udiff in this workflow.
    # 'whole' is the safest fallback: the model rewrites the entire file, eliminating
    # all diff-format parsing issues.
    MODEL_EDIT_FORMAT="whole"
    SERVER_EXTRA_FLAGS=""

elif [ "$SELECTED_MODEL" = "nemotron-nano-30b" ]; then
    MODEL_URL="https://huggingface.co/unsloth/Nemotron-3-Nano-30B-A3B-GGUF/resolve/main/Nemotron-3-Nano-30B-A3B-Q4_K_M.gguf?download=true"
    MODEL_NAME="Nemotron-3-Nano-30B-A3B-Q4_K_M.gguf"
    AIDER_MODEL_ID="nemotron-nano-30b"
    MODEL_NOTE="Nvidia Mamba-2/MoE hybrid. 3.6B active params. Native thinking via <think>. NOT validated in this workflow yet."
    MODEL_MIN_BYTES=24000000000
    MODEL_RAM_GB=32
    MODEL_HAS_THINKING=true
    MODEL_CTX_SIZE=524288
    MODEL_MAX_OUT=32768
    MODEL_TEMPERATURE=0.6
    # 'udiff': Nemotron uses standard <think>...</think> tag (reasoning_tag:think
    # handles stripping). udiff chosen over diff for same reasoning as Qwen3 family.
    # Validate with a small task first; downgrade to 'diff' if loops appear.
    MODEL_EDIT_FORMAT="udiff"
    SERVER_EXTRA_FLAGS=""

elif [ "$SELECTED_MODEL" = "custom" ]; then
    if [ -z "$CUSTOM_MODEL_URL" ] || [ -z "$CUSTOM_MODEL_NAME" ]; then
        echo "ERROR: Para el modo 'custom' debes definir las variables de entorno necesarias."
        exit 1
    fi
    MODEL_URL="$CUSTOM_MODEL_URL"
    MODEL_NAME="$CUSTOM_MODEL_NAME"
    AIDER_MODEL_ID="${CUSTOM_AIDER_ID:-custom-model}"
    MODEL_NOTE="Modelo personalizado proporcionado por el usuario."
    MODEL_MIN_BYTES="${CUSTOM_MODEL_MIN_BYTES:-100000000}"
    MODEL_RAM_GB="${CUSTOM_MODEL_RAM_GB:-16}"
    MODEL_HAS_THINKING="${CUSTOM_MODEL_HAS_THINKING:-false}"
    MODEL_CTX_SIZE="${CUSTOM_CTX_SIZE:-16384}"
    MODEL_MAX_OUT="${CUSTOM_MAX_OUT:-8192}"
    MODEL_TEMPERATURE="${CUSTOM_TEMPERATURE:-0.3}"
    MODEL_EDIT_FORMAT="${CUSTOM_EDIT_FORMAT:-diff}"
    SERVER_EXTRA_FLAGS="${CUSTOM_SERVER_FLAGS:-}"

else
    echo "ERROR: Modelo '$SELECTED_MODEL' no reconocido."
    exit 1
fi

echo "Cargando $SELECTED_MODEL... Requiere aprox $MODEL_RAM_GB GB de RAM."
MODEL_PATH="./models/$MODEL_NAME"

# ─── Resumen de lo que se va a hacer ──────────────────────────────────────────

echo "============================================================"
echo "  switch_model.sh — Selector de modelo LLM para HPC Coder"
echo "============================================================"
echo ""
echo "  Modelo seleccionado : $SELECTED_MODEL"
echo "  Archivo GGUF        : $MODEL_NAME"
echo "  Ruta local          : $MODEL_PATH"
echo "  Identificador Aider : openai/$AIDER_MODEL_ID"
echo "  Thinking            : $MODEL_HAS_THINKING"
echo "  Contexto llama.cpp  : $MODEL_CTX_SIZE tokens"
echo "  Nota                : $MODEL_NOTE"
echo ""

# ─── Advertencia para modelos muy pesados ────────────────────────────────────

if [ "$SELECTED_MODEL" = "mistral-small" ]; then
    echo "AVISO: Mistral Small 4 es un modelo de 119B parametros (~65 GB en Q4_K_M)."
    echo "Asegurate de que el nodo de computo tiene suficiente RAM antes de enviar el job."
    echo "Continuando en 5 segundos... (Ctrl+C para cancelar)"
    sleep 5
fi

# ─── 1. Verificar / Descargar el modelo ───────────────────────────────────────

mkdir -p ./models

echo "=== [1/3] Verificando si el modelo ya esta descargado ==="

# Comprobamos la existencia Y el tamaño minimo del archivo.
# Esto evita confundir un archivo de un modelo distinto (o una descarga
# incompleta/corrupta) con el modelo correcto.
if [ -f "$MODEL_PATH" ]; then
    LOCAL_SIZE=$(stat -c%s "$MODEL_PATH" 2>/dev/null || stat -f%z "$MODEL_PATH" 2>/dev/null || echo 0)
    echo "Archivo encontrado: $MODEL_PATH"
    echo "Tamaño local    : $LOCAL_SIZE bytes"
    echo "Tamaño minimo   : $MODEL_MIN_BYTES bytes"

    if [ "$LOCAL_SIZE" -ge "$MODEL_MIN_BYTES" ]; then
        echo "El modelo esta completo y disponible localmente. Omitiendo descarga."
    else
        echo ""
        echo "AVISO: El archivo existe pero pesa menos de lo esperado."
        echo "Puede ser una descarga incompleta o un modelo diferente en la misma ruta."
        echo "Reanudando/sobreescribiendo descarga..."
        echo "URL: $MODEL_URL"
        echo ""
        wget --continue --show-progress -O "$MODEL_PATH" "$MODEL_URL"
        echo ""
        echo "Descarga completada: $MODEL_PATH"
    fi
else
    echo "Modelo no encontrado en $MODEL_PATH. Iniciando descarga..."
    echo "URL: $MODEL_URL"
    echo ""
    # --continue permite reanudar si la red falla a mitad
    wget --continue --show-progress -O "$MODEL_PATH" "$MODEL_URL"
    echo ""
    echo "Descarga completada: $MODEL_PATH"
fi

# ─── 2. Actualizar submit_job.sh ──────────────────────────────────────────────

echo ""
echo "=== [2/3] Actualizando submit_job.sh ==="

SUBMIT_SCRIPT="./submit_job.sh"

if [ ! -f "$SUBMIT_SCRIPT" ]; then
    echo "AVISO: $SUBMIT_SCRIPT no encontrado. Omitiendo este paso."
else
    # Hacemos backup antes de modificar
    cp "$SUBMIT_SCRIPT" "${SUBMIT_SCRIPT}.bak"
    echo "Backup creado: ${SUBMIT_SCRIPT}.bak"

    # Actualizar la ruta del modelo
    sed -i "s|^MODEL_PATH=.*|MODEL_PATH=\"\$(pwd)/models/$MODEL_NAME\"|" "$SUBMIT_SCRIPT"
    echo "  MODEL_PATH   -> ./models/$MODEL_NAME"

    # Actualizar el tamano de contexto del servidor llama.cpp
    sed -i "s|--ctx-size [0-9]*|--ctx-size $MODEL_CTX_SIZE|g" "$SUBMIT_SCRIPT"
    
    # Gestionar flags de razonamiento (ej: --reasoning-format deepseek para Gemma4)
    # Primero limpiamos cualquier flag de razonamiento previo
    sed -i "s|--reasoning-format [a-z]*||g" "$SUBMIT_SCRIPT"
    # Insertamos el nuevo flag si existe, justo despues de ./bin/llama-server
    if [ -n "$SERVER_EXTRA_FLAGS" ]; then
        sed -i "s|\./bin/llama-server |\./bin/llama-server $SERVER_EXTRA_FLAGS |" "$SUBMIT_SCRIPT"
    fi
    # Limpieza de espacios dobles
    sed -i "s|  | |g" "$SUBMIT_SCRIPT"
    
    echo "  --ctx-size    -> $MODEL_CTX_SIZE tokens"
    echo "  Server Flags  -> $SERVER_EXTRA_FLAGS"
fi

# ─── 3. Actualizar run_loop.sh ────────────────────────────────────────────────

echo ""
echo "=== [3/3] Actualizando run_loop.sh ==="

RUN_SCRIPT="./run_loop.sh"

if [ ! -f "$RUN_SCRIPT" ]; then
    echo "AVISO: $RUN_SCRIPT no encontrado. Omitiendo este paso."
else
    # Hacemos backup antes de modificar
    cp "$RUN_SCRIPT" "${RUN_SCRIPT}.bak"
    echo "Backup creado: ${RUN_SCRIPT}.bak"

    # Actualizar la variable AIDER_MODEL (nombre del modelo que usa Aider)
    sed -i "s|^AIDER_MODEL=.*|AIDER_MODEL=\"openai/$AIDER_MODEL_ID\"|" "$RUN_SCRIPT"
    echo "  AIDER_MODEL        -> openai/$AIDER_MODEL_ID"

    # Actualizar el flag de thinking del modelo
    sed -i "s|^MODEL_HAS_THINKING=.*|MODEL_HAS_THINKING=$MODEL_HAS_THINKING|" "$RUN_SCRIPT"
    echo "  MODEL_HAS_THINKING -> $MODEL_HAS_THINKING"

    # Actualizar el tamano de contexto para Aider
    sed -i "s|^MODEL_CTX_SIZE=.*|MODEL_CTX_SIZE=$MODEL_CTX_SIZE|" "$RUN_SCRIPT"
    echo "  MODEL_CTX_SIZE     -> $MODEL_CTX_SIZE"

    # Actualizar el limite de salida para Aider
    sed -i "s|^MODEL_MAX_OUT=.*|MODEL_MAX_OUT=$MODEL_MAX_OUT|" "$RUN_SCRIPT"
    echo "  MODEL_MAX_OUT      -> $MODEL_MAX_OUT"

    # Actualizar temperatura de muestreo (usada tanto en extra_params como en top-level
    # context_window/max_tokens del YAML generado dinamicamente en run_loop.sh)
    sed -i "s|^MODEL_TEMPERATURE=.*|MODEL_TEMPERATURE=$MODEL_TEMPERATURE|" "$RUN_SCRIPT"
    echo "  MODEL_TEMPERATURE  -> $MODEL_TEMPERATURE"

    # Actualizar el formato de edicion de Aider (diff / udiff / whole)
    sed -i "s|^MODEL_EDIT_FORMAT=.*|MODEL_EDIT_FORMAT=\"$MODEL_EDIT_FORMAT\"|" "$RUN_SCRIPT"
    echo "  MODEL_EDIT_FORMAT  -> $MODEL_EDIT_FORMAT"
fi

# ─── Resumen final ────────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "  Configuracion aplicada con exito"
echo "============================================================"
echo ""
echo "  Modelo activo  : $MODEL_NAME"
echo "  Thinking       : $MODEL_HAS_THINKING"
echo "  Contexto       : $MODEL_CTX_SIZE tokens"
echo ""
echo "  submit_job.sh  : MODEL_PATH    -> ./models/$MODEL_NAME"
echo "  submit_job.sh  : --ctx-size    -> $MODEL_CTX_SIZE"
echo "  submit_job.sh  : Server Flags  -> $SERVER_EXTRA_FLAGS"
echo "  run_loop.sh    : AIDER_MODEL        -> openai/$AIDER_MODEL_ID"
echo "  run_loop.sh    : MODEL_HAS_THINKING -> $MODEL_HAS_THINKING"
echo "  run_loop.sh    : MODEL_CTX_SIZE     -> $MODEL_CTX_SIZE"
echo "  run_loop.sh    : MODEL_MAX_OUT      -> $MODEL_MAX_OUT"
echo "  run_loop.sh    : MODEL_TEMPERATURE  -> $MODEL_TEMPERATURE"
echo "  run_loop.sh    : MODEL_EDIT_FORMAT  -> $MODEL_EDIT_FORMAT"
echo ""
echo "  Backups disponibles:"
[ -f "${SUBMIT_SCRIPT}.bak" ] && echo "    ${SUBMIT_SCRIPT}.bak"
[ -f "${RUN_SCRIPT}.bak"    ] && echo "    ${RUN_SCRIPT}.bak"
echo ""
echo "  Para lanzar el job en SGE: qsub submit_job.sh"
echo "============================================================"
