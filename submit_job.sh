#!/bin/bash
#$ -u pgarazn
#$ -N aidsorber
#$ -V
#$ -m e
#$ -e ai.err
#$ -pe mp 12
#$ -l h_vmem=6G
#$ -l h_rt=48:00:00
#$ -cwd
#$ -j y
#$ -o logs/job_$JOB_ID.log


echo "=== Job started on $(hostname) at $(date) ==="

WORKSPACE_DIR="$(pwd)/workspace"
MODEL_PATH="$(pwd)/models/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"

# Maximum number of Aider→test→fix iterations before the loop exits.
# Increase for complex tasks, decrease for quick sanity checks.
MAX_ITERATIONS=25

# Set to true to wipe Aider session state and generated binary outputs before
# starting. Use when changing the task or the model.
# Set to false to resume an interrupted job from where it left off.
FRESH_START=true

# Llama.cpp usara de manera 100% nativa la misma cantidad de hilos alojados por SGE para SMP
export OMP_NUM_THREADS=$NSLOTS

echo "Starting llama-server via SMP multi-threading on $NSLOTS cores..."
# Ejecutamos con threading (-t $NSLOTS), abriendo el puerto 11434 compatible con OpenAI Server
./bin/llama-server -m "$MODEL_PATH" --host 0.0.0.0 --port 11434 -t $NSLOTS --ctx-size 262144 > logs/llama_server_$JOB_ID.log 2>&1 &
SERVER_PID=$!

echo "Waiting for llama.cpp server to be ready (polling /health)..."
MAX_WAIT=600 # 10 minutos de timeout maximo (modelos grandes tardan en hacer warmup)
ELAPSED=0
POLL_INTERVAL=10
while [ $ELAPSED -lt $MAX_WAIT ]; do
 # El endpoint /health devuelve {"status":"ok"} cuando el modelo esta listo
 # y {"status":"loading model"} mientras carga. curl falla si el servidor
 # aun no escucha en el puerto, por eso redirigimos stderr a /dev/null.
 HEALTH=$(curl -s --max-time 5 "http://localhost:11434/health" 2>/dev/null || echo "unavailable")
 if echo "$HEALTH" | grep -q '"status":"ok"'; then
 echo "Server ready after ${ELAPSED}s. Launching AI coding agent..."
 break
 fi
 sleep $POLL_INTERVAL
 ELAPSED=$((ELAPSED + POLL_INTERVAL))
 echo " [${ELAPSED}s] Server not ready yet... (response: $HEALTH)"
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
 echo "ERROR: llama.cpp server did not become ready within ${MAX_WAIT}s. Aborting job."
 kill $SERVER_PID 2>/dev/null || true
 exit 1
fi

cp run_loop.sh workspace/run_loop.sh
sed -i 's/\r$//' workspace/run_loop.sh

apptainer exec \
 --contain \
 --no-home \
 --home /workspace \
 --bind ./workspace:/workspace \
 --bind ./libs:/libs:ro \
 --pwd /workspace \
 --env MAX_ITERATIONS=$MAX_ITERATIONS \
 --env FRESH_START=$FRESH_START \
 agent_env.sif bash /workspace/run_loop.sh

AGENT_EXIT=$?

echo "Shutting down llama.cpp server (PID $SERVER_PID)..."
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo "=== Job finished at $(date) with exit code $AGENT_EXIT ==="
exit $AGENT_EXIT
