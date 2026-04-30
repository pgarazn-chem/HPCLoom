#!/bin/bash
# build_env.sh
# Preparacion completa del entorno HPC AI Coder.
# Ejecutar UNA VEZ en el nodo de inicio (login node).

set -e

echo "=== Construyendo entorno HPC AI Coder ==="

# Limpieza de seguridad
rm -rf ./llama.cpp ./bin

# 1. Crear directorios
mkdir -p ./models ./workspace ./bin ./logs ./libs

# 2. Descargar imagen Apptainer
echo "[1/3] Descargando imagen de Apptainer segura..."
if [ ! -f "agent_env.sif" ]; then
    apptainer pull agent_env.sif docker://python:3.11
else
    echo "Imagen agent_env.sif ya existe."
fi

echo "[2/3] Pre-instalando dependencias de Python (Aider) de forma local..."
if [ ! -d "./libs/aider" ]; then
    apptainer exec --bind ./libs:/libs agent_env.sif pip install --no-cache-dir --target /libs aider-chat cowsay matplotlib pytest pandas numpy scipy seaborn
else
    echo "Dependencias de Python ya instaladas en ./libs."
fi

# 3. Descargar y Compilar llama.cpp con MPI
echo "[3/3] Descargando y compilando llama.cpp con soporte multi-hilo..."
if [ ! -d "llama.cpp" ]; then
    git clone https://github.com/ggerganov/llama.cpp.git
fi
cd llama.cpp


# Eliminado modulo MPI temporalmente
# module load openmpi ...

echo "Compilando llama.cpp con CMake (soporte multi-hilo)..."
cmake -B build
cmake --build build --config Release -j4
cp build/bin/llama-server ../bin/
cd ..

echo ""
echo "=== Setup complete ==="
echo "First step : bash switch_model.sh [MODEL]   (descarga el modelo y configura los scripts)"
echo "Second step: qsub submit_job.sh              (lanza el job en SGE)"
