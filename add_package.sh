#!/bin/bash
# add_package.sh
# Instala paquetes adicionales de Python en el directorio local ./libs usando Apptainer.
# Estos paquetes estaran automaticamente disponibles para Aider y cualquier script que escriba.
#
# Uso:
#   bash add_package.sh <package1> [package2 ...]
# Ejemplo:
#   bash add_package.sh ase pandas numpy

if [ "$#" -eq 0 ]; then
    echo "Error: Debes especificar al menos un paquete para instalar."
    echo "Uso: bash add_package.sh <package1> [package2 ...]"
    exit 1
fi

if [ ! -f "agent_env.sif" ]; then
    echo "Error: agent_env.sif no encontrado. ¿Has ejecutado build_env.sh primero?"
    exit 1
fi

if [ ! -d "./libs" ]; then
    mkdir -p ./libs
fi

echo "=== Instalando paquetes: $@ ==="
# Usamos pip install --target dentro del contenedor para instalarlo en el 
# directorio mapeado localmente sin alterar la imagen del contenedor.
apptainer exec --bind ./libs:/libs agent_env.sif pip install --no-cache-dir --target /libs "$@"

echo ""
echo "=== ¡Instalacion completada! ==="
echo "Los paquetes estaran disponibles via PYTHONPATH durante la ejecucion del job."
