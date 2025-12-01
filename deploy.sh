#!/bin/bash

# =============================================================================
# OBSERVABILITY PLATFORM - DEPLOYMENT SCRIPT
# =============================================================================
# Este script automatiza la configuración y despliegue del stack de observabilidad
# con cluster OpenSearch de 3 nodos y Nginx Load Balancer
# =============================================================================

set -e  # Detener ejecución si hay algún error

# Función de cleanup para archivos temporales
cleanup() {
    rm -f docker-compose.tmp.yml docker-compose.new.yml *.bak Endpoints/*.bak Grafana/*.bak 2>/dev/null || true
}
trap cleanup EXIT

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Variables globales
AUTO_MODE=false
WINDOWS_SERVER_COUNT=1

# Función para imprimir mensajes
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Función para validar IP
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Parsear argumentos
for arg in "$@"
do
    case $arg in
        --auto)
        AUTO_MODE=true
        shift # Remove --auto from processing
        ;;
        *)
        # Unknown option
        ;;
    esac
done

# Banner
echo -e "${GREEN}"
cat << "EOF"
--------------------------------------------------------------
   ___  _                                        
  / _ \| |__  ___  ___ _ ____   ____ _| |__ (_) (_) |_ _   _  
 | | | | '_ \/ __|/ _ \ '__\ \ / / _` | '_ \| | | | __| | | | 
 | |_| | |_) \__ \  __/ |   \ V / (_| | |_) | | | | |_| |_| | 
  \___/|_.__/|___/\___|_|    \_/ \__,_|_.__/|_|_|_|\__|\__, | 
                                                        |___/  
     ____  _       _    __                         
    |  _ \| | __ _| |_ / _| ___  _ __ _ __ ___     
    | |_) | |/ _` | __| |_ / _ \| '__| '_ ` _ \    
    |  __/| | (_| | |_|  _| (_) | |  | | | | | |   
    |_|   |_|\__,_|\__|_|  \___/|_|  |_| |_| |_|  by @blakpat
 --------------------------------------------------------------                                                   
  ╔════════════════════════════════════════════════════════╗
  ║  Stack: OpenSearch HA + Prometheus + Grafana + OTel    ║
  ║  Deployment Script v1.0                                ║
  ╚════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# =============================================================================
# ETAPA 1: VERIFICACIÓN DE DEPENDENCIAS
# =============================================================================

print_info "Verificando dependencias..."

if ! command -v docker &> /dev/null; then
    print_error "Docker no está instalado. Por favor, instala Docker primero."
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    print_error "Docker Compose no está instalado. Por favor, instala Docker Compose primero."
    exit 1
fi

print_success "Docker y Docker Compose están instalados"

# =============================================================================
# ETAPA 2: CARGA DE CONFIGURACIÓN
# =============================================================================

if [ "$AUTO_MODE" = true ]; then
    print_info "Modo AUTOMÁTICO activado"
    if [ ! -f ".env" ] && [ -f ".env.example" ]; then
        print_info "Copiando .env.example a .env..."
        cp .env.example .env
    elif [ ! -f ".env" ]; then
        print_error "No se encontró .env ni .env.example para modo automático."
        exit 1
    fi
fi

# Cargar variables del archivo .env si existe
if [ -f ".env" ]; then
    print_info "Cargando configuración desde .env..."
    source .env
    USE_ENV_FILE=true
    
    # Validar WINDOWS_SERVER_COUNT
    if ! [[ "$WINDOWS_SERVER_COUNT" =~ ^[0-9]+$ ]] || [ "$WINDOWS_SERVER_COUNT" -lt 1 ]; then
        print_warning "WINDOWS_SERVER_COUNT inválido ($WINDOWS_SERVER_COUNT), usando 1 por defecto"
        WINDOWS_SERVER_COUNT=1
    fi
    
    # Mapeo de variables para compatibilidad en modo AUTO
    # Si usamos el formato nuevo (WINDOWS_1_...) pero el script espera las variables legacy para el primer server
    if [ -z "$SQL_SERVER_HOST" ] && [ ! -z "$WINDOWS_1_SQL_HOST" ]; then
        print_info "Mapeando configuración del Servidor #1..."
        WINDOWS_SERVER_IP=$WINDOWS_1_IP
        SQL_SERVER_HOST=$WINDOWS_1_SQL_HOST
        SQL_DATABASE=$WINDOWS_1_SQL_DATABASE
        SQL_USERNAME=$WINDOWS_1_SQL_USERNAME
        SQL_PASSWORD=$WINDOWS_1_SQL_PASSWORD
    fi
else
    USE_ENV_FILE=false
fi

# =============================================================================
# ETAPA 3: RECOLECCIÓN DE PARÁMETROS (Modo Interactivo)
# =============================================================================

if [ "$AUTO_MODE" = false ]; then
    echo ""
    print_info "Configuración del servidor de infraestructura:"
    echo ""

    # IP del servidor de infraestructura
    if [ "$USE_ENV_FILE" = true ] && [ ! -z "$INFRA_SERVER_IP" ]; then
        read -p "IP del servidor de infraestructura [${INFRA_SERVER_IP}]: " input
        INFRA_SERVER_IP=${input:-$INFRA_SERVER_IP}
    else
        read -p "IP del servidor de infraestructura (donde corre Docker): " INFRA_SERVER_IP
        while ! validate_ip "$INFRA_SERVER_IP"; do
            print_error "IP inválida. Por favor, ingresa una IP válida."
            read -p "IP del servidor de infraestructura: " INFRA_SERVER_IP
        done
    fi

    # Si no está definido WINDOWS_SERVER_COUNT, asumir 1 para modo interactivo simple
    # (El modo interactivo completo para múltiples servidores requeriría un bucle complejo,
    #  por ahora mantenemos compatibilidad con el flujo simple o asumimos edición manual de .env)
    echo ""
    print_info "Configuración del servidor Windows:"
    echo ""

    # IP del servidor Windows
    if [ "$USE_ENV_FILE" = true ] && [ ! -z "$WINDOWS_SERVER_IP" ]; then
        read -p "IP del servidor Windows [${WINDOWS_SERVER_IP}]: " input
        WINDOWS_SERVER_IP=${input:-$WINDOWS_SERVER_IP}
    else
        read -p "IP del servidor Windows (Windows Exporter + SQL Server): " WINDOWS_SERVER_IP
        while ! validate_ip "$WINDOWS_SERVER_IP"; do
            print_error "IP inválida. Por favor, ingresa una IP válida."
            read -p "IP del servidor Windows: " WINDOWS_SERVER_IP
        done
    fi

    echo ""
    print_info "Configuración de SQL Server:"
    echo ""

    # Configuración de SQL Server
    if [ "$USE_ENV_FILE" = true ] && [ ! -z "$SQL_SERVER_HOST" ]; then
        read -p "Host de SQL Server [${SQL_SERVER_HOST}]: " input
        SQL_SERVER_HOST=${input:-$SQL_SERVER_HOST}
    else
        read -p "Host de SQL Server [${WINDOWS_SERVER_IP}]: " SQL_SERVER_HOST
        SQL_SERVER_HOST=${SQL_SERVER_HOST:-$WINDOWS_SERVER_IP}
    fi

    if [ "$USE_ENV_FILE" = true ] && [ ! -z "$SQL_DATABASE" ]; then
        read -p "Nombre de la base de datos [${SQL_DATABASE}]: " input
        SQL_DATABASE=${input:-$SQL_DATABASE}
    else
        read -p "Nombre de la base de datos a monitorear: " SQL_DATABASE
    fi

    if [ "$USE_ENV_FILE" = true ] && [ ! -z "$SQL_USERNAME" ]; then
        read -p "Usuario de SQL Server [${SQL_USERNAME}]: " input
        SQL_USERNAME=${input:-$SQL_USERNAME}
    else
        read -p "Usuario de SQL Server [mssql_exporter]: " SQL_USERNAME
        SQL_USERNAME=${SQL_USERNAME:-mssql_exporter}
    fi

    if [ "$USE_ENV_FILE" = true ] && [ ! -z "$SQL_PASSWORD" ]; then
        read -sp "Password de SQL Server [usar existente]: " input
        echo ""
        SQL_PASSWORD=${input:-$SQL_PASSWORD}
    else
        read -sp "Password de SQL Server: " SQL_PASSWORD
        echo ""
    fi

    echo ""
    print_info "Configuración de OpenSearch:"
    echo ""

    # Password de OpenSearch
    if [ "$USE_ENV_FILE" = true ] && [ ! -z "$OPENSEARCH_ADMIN_PASSWORD" ]; then
        read -sp "Password del admin de OpenSearch [usar existente]: " input
        echo ""
        OPENSEARCH_ADMIN_PASSWORD=${input:-$OPENSEARCH_ADMIN_PASSWORD}
    else
        print_warning "El password debe tener mínimo 8 caracteres, mayúsculas, minúsculas, números y símbolos"
        read -sp "Password del admin de OpenSearch: " OPENSEARCH_ADMIN_PASSWORD
        echo ""
    fi

    echo ""
    print_info "Configuración de Email/SMTP (Opcional - para alertas de Grafana):"
    echo ""

    # Configuración SMTP (opcional)
    read -p "¿Configurar SMTP para notificaciones? (y/n) [n]: " CONFIGURE_SMTP
    CONFIGURE_SMTP=${CONFIGURE_SMTP:-n}

    if [[ "$CONFIGURE_SMTP" =~ ^[Yy]$ ]]; then
        read -p "Host SMTP (ej: smtp.gmail.com:587): " SMTP_HOST
        read -p "Usuario SMTP: " SMTP_USER
        read -sp "Password SMTP: " SMTP_PASSWORD
        echo ""
        read -p "Email remitente: " SMTP_FROM_ADDRESS
        read -p "Nombre remitente [Alertas Observabilidad]: " SMTP_FROM_NAME
        SMTP_FROM_NAME=${SMTP_FROM_NAME:-Alertas Observabilidad}
    fi

    echo ""
    print_info "Configuración de Dashboards de Grafana (Opcional):"
    echo ""

    # Importar dashboards automáticamente
    read -p "¿Quieres importar automáticamente los dashboards de Grafana? (y/n) [y]: " IMPORT_DASHBOARDS
    IMPORT_DASHBOARDS=${IMPORT_DASHBOARDS:-y}

    # Guardar configuración en .env
    print_info "Guardando configuración en .env..."
    cat > .env << EOF
# Configuración del Stack de Observabilidad
# Generado el: $(date)

# Servidor de Infraestructura
INFRA_SERVER_IP=${INFRA_SERVER_IP}

# Servidor Windows
WINDOWS_SERVER_IP=${WINDOWS_SERVER_IP}
WINDOWS_SERVER_COUNT=1

# SQL Server
SQL_SERVER_HOST=${SQL_SERVER_HOST}
SQL_DATABASE=${SQL_DATABASE}
SQL_USERNAME=${SQL_USERNAME}
SQL_PASSWORD=${SQL_PASSWORD}

# OpenSearch
OPENSEARCH_ADMIN_PASSWORD=${OPENSEARCH_ADMIN_PASSWORD}

# SMTP (Opcional)
SMTP_ENABLED=${CONFIGURE_SMTP}
SMTP_HOST=${SMTP_HOST}
SMTP_USER=${SMTP_USER}
SMTP_PASSWORD=${SMTP_PASSWORD}
SMTP_FROM_ADDRESS=${SMTP_FROM_ADDRESS}
SMTP_FROM_NAME=${SMTP_FROM_NAME}

# Dashboards
IMPORT_DASHBOARDS=${IMPORT_DASHBOARDS}
EOF

    print_success "Configuración guardada en .env"
fi

# =============================================================================
# ETAPA 4: CONFIGURACIÓN DE ARCHIVOS
# =============================================================================

print_info "Aplicando configuración a los archivos..."

# Backup de archivos originales
backup_dir="backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$backup_dir"
cp prometheus.yml "$backup_dir/"
cp docker-compose.yml "$backup_dir/"
cp Endpoints/otel-config.yaml "$backup_dir/"
if [ -f custom.ini ]; then
    cp custom.ini "$backup_dir/"
fi
print_success "Backup de archivos originales guardado en $backup_dir"

# -----------------------------------------------------------------------------
# 4.1 Configurar Prometheus
# -----------------------------------------------------------------------------

print_info "Configurando Prometheus..."

# Construir lista de targets para Windows Exporter
WINDOWS_TARGETS=""
MSSQL_TARGETS=""

for (( i=1; i<=WINDOWS_SERVER_COUNT; i++ ))
do
    # Obtener IP usando variable indirecta
    # En bash, para acceder a variables dinámicas como WINDOWS_1_IP
    if [ $i -eq 1 ]; then
        # Fallback para el primer servidor si usa variables legacy
        VAR_IP="WINDOWS_1_IP"
        CURRENT_IP="${!VAR_IP}"
        if [ -z "$CURRENT_IP" ]; then CURRENT_IP="$WINDOWS_SERVER_IP"; fi
        
        VAR_HAS_SQL="WINDOWS_1_HAS_SQL"
        HAS_SQL="${!VAR_HAS_SQL}"
        # Si no está definida la variable HAS_SQL, asumimos que si hay SQL_SERVER_HOST definido, entonces sí (legacy)
        if [ -z "$HAS_SQL" ] && [ ! -z "$SQL_SERVER_HOST" ]; then HAS_SQL="y"; fi
    else
        VAR_IP="WINDOWS_${i}_IP"
        CURRENT_IP="${!VAR_IP}"
        
        VAR_HAS_SQL="WINDOWS_${i}_HAS_SQL"
        HAS_SQL="${!VAR_HAS_SQL}"
    fi
    
    if [ -z "$CURRENT_IP" ]; then
        print_warning "IP para servidor $i no encontrada (Variable WINDOWS_${i}_IP), saltando..."
        continue
    fi
    
    # Agregar a targets de windows
    if [ -z "$WINDOWS_TARGETS" ]; then
        WINDOWS_TARGETS="'${CURRENT_IP}:9182'"
    else
        WINDOWS_TARGETS="${WINDOWS_TARGETS}, '${CURRENT_IP}:9182'"
    fi
    
    # Verificar si tiene SQL
    if [[ "$HAS_SQL" =~ ^[Yy]$ ]]; then
        # Agregar a targets de mssql (nombre del servicio docker)
        # Para el servidor 1, el servicio se llama 'mssql-exporter' (legacy)
        # Para otros, 'mssql-exporter-N'
        if [ $i -eq 1 ]; then
            SERVICE_NAME="mssql-exporter"
        else
            SERVICE_NAME="mssql-exporter-${i}"
        fi
        
        if [ -z "$MSSQL_TARGETS" ]; then
            MSSQL_TARGETS="'${SERVICE_NAME}:4000'"
        else
            MSSQL_TARGETS="${MSSQL_TARGETS}, '${SERVICE_NAME}:4000'"
        fi
    fi
done

# Escribir prometheus.yml
cat > prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'windows'
    static_configs:
      - targets: [${WINDOWS_TARGETS}]

  - job_name: 'mssql_exporter'
    static_configs:
      - targets: [${MSSQL_TARGETS}]
EOF

print_success "Prometheus configurado con targets: Windows=[${WINDOWS_TARGETS}], SQL=[${MSSQL_TARGETS}]"

# -----------------------------------------------------------------------------
# 4.2 Configurar Docker Compose
# -----------------------------------------------------------------------------

print_info "Generando configuración de Docker Compose..."

# Hacemos una copia temporal
cp docker-compose.yml docker-compose.tmp.yml

# Eliminar el servicio mssql-exporter estático si existe para regenerarlo dinámicamente
# (O mantenerlo para el 1 y añadir los demás. Vamos a mantener el 1 como base y añadir los otros)

# Configurar variables del primer servidor (mssql-exporter original) - optimizado con una sola llamada sed
sed -i -e "s/SERVER=change_me/SERVER=${SQL_SERVER_HOST}/g" \
       -e "s/USERNAME=change_me/USERNAME=${SQL_USERNAME}/g" \
       -e "s/PASSWORD=change_me/PASSWORD=${SQL_PASSWORD}/g" \
       -e "s/DATABASE=change_me/DATABASE=${SQL_DATABASE}/g" \
       docker-compose.tmp.yml

# Ahora añadimos los servicios adicionales (del 2 en adelante)
for (( i=2; i<=WINDOWS_SERVER_COUNT; i++ ))
do
    VAR_HAS_SQL="WINDOWS_${i}_HAS_SQL"
    HAS_SQL="${!VAR_HAS_SQL}"
    
    if [[ "$HAS_SQL" =~ ^[Yy]$ ]]; then
        VAR_SQL_HOST="WINDOWS_${i}_SQL_HOST"
        VAR_SQL_DB="WINDOWS_${i}_SQL_DATABASE"
        VAR_SQL_USER="WINDOWS_${i}_SQL_USERNAME"
        VAR_SQL_PASS="WINDOWS_${i}_SQL_PASSWORD"
        
        # Generar bloque de servicio
        # Nota: Usamos echo con saltos de línea escapados para asegurar formato YAML
        SERVICE_BLOCK="
  mssql-exporter-${i}:
    image: awaragi/prometheus-mssql-exporter:latest
    container_name: mssql-exporter-${i}
    environment:
      - SERVER=${!VAR_SQL_HOST}
      - USERNAME=${!VAR_SQL_USER}
      - PASSWORD=${!VAR_SQL_PASS}
      - DATABASE=${!VAR_SQL_DB}
    ports:
      - \"400${i}:4000\"
    networks:
      - observability
    restart: unless-stopped"
    
        # Insertar antes de "volumes:"
        # Usamos un archivo temporal intermedio para concatenar
        # Estrategia: Cortar el archivo antes de volumes, añadir servicio, añadir resto
        LINE_NUM=$(grep -n "^volumes:" docker-compose.tmp.yml | cut -d: -f1 | head -n 1)
        if [ ! -z "$LINE_NUM" ]; then
            head -n $((LINE_NUM-1)) docker-compose.tmp.yml > docker-compose.new.yml
            echo "$SERVICE_BLOCK" >> docker-compose.new.yml
            tail -n +$LINE_NUM docker-compose.tmp.yml >> docker-compose.new.yml
            mv docker-compose.new.yml docker-compose.tmp.yml
        else
            print_error "No se encontró la sección 'volumes:' en docker-compose.yml"
        fi
    fi
done

# Reemplazar variables globales en el resto del archivo
sed -i "s/OPENSEARCH_INITIAL_ADMIN_PASSWORD=change_me/OPENSEARCH_INITIAL_ADMIN_PASSWORD=${OPENSEARCH_ADMIN_PASSWORD}/g" docker-compose.tmp.yml
# Si ya estaba configurado, asegurarnos de que se actualice
sed -i "s/OPENSEARCH_INITIAL_ADMIN_PASSWORD=[^ ]*/OPENSEARCH_INITIAL_ADMIN_PASSWORD=${OPENSEARCH_ADMIN_PASSWORD}/g" docker-compose.tmp.yml

mv docker-compose.tmp.yml docker-compose.yml
print_success "Docker Compose configurado con múltiples exportadores SQL"

# -----------------------------------------------------------------------------
# 4.3 Configurar OTel Collector
# -----------------------------------------------------------------------------

print_info "Configurando OTel Collector para Windows..."
sed -i.bak "s|http://change_me:9200|http://${INFRA_SERVER_IP}:9200|g" Endpoints/otel-config.yaml
# Si ya estaba configurado:
sed -i.bak "s|http://.*:9200|http://${INFRA_SERVER_IP}:9200|g" Endpoints/otel-config.yaml
print_success "OTel Collector configurado"

# -----------------------------------------------------------------------------
# 4.4 Configurar Grafana Dashboards
# -----------------------------------------------------------------------------

print_info "Configurando dashboards de Grafana..."
# Backup de dashboards
cp Grafana/dashboard_main_sw.json "$backup_dir/" 2>/dev/null || true
cp Grafana/"Microsoft SQL Server.json" "$backup_dir/" 2>/dev/null || true

# Reemplazar IPs antiguas en los dashboards por la IP del PRIMER servidor Windows (Limitación actual de dashboards estáticos)
# Idealmente los dashboards deberían usar variables de Grafana.
# Por ahora, usamos WINDOWS_1_IP como principal.
WINDOWS_1_IP_VAL=${WINDOWS_1_IP:-$WINDOWS_SERVER_IP}
find Grafana -name "*.json" -type f ! -path "*/provisioning/*" -exec sed -i.bak "s/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:9182/${WINDOWS_1_IP_VAL}:9182/g" {} \;

# Corregir UIDs del datasource Prometheus a 'df40idfkmj3swe' (matchea con provisioning)
print_info "Corrigiendo UIDs de datasource en dashboards..."
find Grafana -name "*.json" -type f ! -path "*/provisioning/*" -exec sed -i "s/\"type\": \"prometheus\",\s*\"uid\": \"[^\"]*\"/\"type\": \"prometheus\", \"uid\": \"df40idfkmj3swe\"/g" {} \;

# Si el usuario quiere importar dashboards, copiarlos a la carpeta de provisioning
if [[ "$IMPORT_DASHBOARDS" =~ ^[Yy]$ ]]; then
    print_info "Copiando dashboards a la carpeta de provisioning..."
    mkdir -p Grafana/provisioning/dashboards/imported
    
    # Copiar dashboards JSON (excluyendo la carpeta provisioning para evitar recursión)
    find Grafana -maxdepth 1 -name "*.json" -type f -exec cp {} Grafana/provisioning/dashboards/imported/ \;
    
    print_success "Dashboards configurados para importación automática"
else
    print_info "Los dashboards NO se importarán automáticamente. Podrás importarlos manualmente desde Grafana UI."
fi

print_success "Dashboards de Grafana configurados"

# -----------------------------------------------------------------------------
# 4.5 Configurar SMTP (Opcional)
# -----------------------------------------------------------------------------

if [[ "$CONFIGURE_SMTP" =~ ^[Yy]$ ]]; then
    print_info "Configurando SMTP en Grafana..."
    cat > custom.ini << EOF
[smtp]
enabled = true
host = ${SMTP_HOST}
user = ${SMTP_USER}
password = ${SMTP_PASSWORD}
from_address = ${SMTP_FROM_ADDRESS}
from_name = ${SMTP_FROM_NAME}
EOF
    print_success "SMTP configurado"
fi

# Los archivos .bak se limpian automáticamente en cleanup (trap EXIT)

# =============================================================================
# ETAPA 5: RESUMEN DE CONFIGURACIÓN
# =============================================================================

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Servidor Infra:     ${GREEN}${INFRA_SERVER_IP}${NC}"
echo -e "  Clientes Windows:   ${GREEN}${WINDOWS_SERVER_COUNT}${NC}"

# Listar clientes con sus IPs
for (( i=1; i<=WINDOWS_SERVER_COUNT; i++ ))
do
    VAR_NAME="WINDOWS_${i}_NAME"
    VAR_IP="WINDOWS_${i}_IP"
    VAR_HAS_SQL="WINDOWS_${i}_HAS_SQL"
    
    CLIENT_NAME="${!VAR_NAME}"
    CLIENT_IP="${!VAR_IP}"
    HAS_SQL="${!VAR_HAS_SQL}"
    
    # Fallback para servidor 1 si usa variables legacy
    if [ $i -eq 1 ]; then
        if [ -z "$CLIENT_NAME" ]; then CLIENT_NAME="Windows-Server-1"; fi
        if [ -z "$CLIENT_IP" ]; then CLIENT_IP="$WINDOWS_SERVER_IP"; fi
        if [ -z "$HAS_SQL" ] && [ ! -z "$SQL_SERVER_HOST" ]; then HAS_SQL="y"; fi
    fi
    
    if [ ! -z "$CLIENT_IP" ]; then
        SQL_STATUS=""
        if [[ "$HAS_SQL" =~ ^[Yy]$ ]]; then
            SQL_STATUS=" ${YELLOW}(SQL)${NC}"
        fi
        echo -e "    • Cliente #${i}:     ${GREEN}${CLIENT_NAME}${NC} - ${GREEN}${CLIENT_IP}${NC}${SQL_STATUS}"
    fi
done

# Estado de SMTP
if [[ "$CONFIGURE_SMTP" =~ ^[Yy]$ ]] || [[ "$SMTP_ENABLED" =~ ^[Yy]$ ]]; then
    echo -e "  SMTP:               ${GREEN}Activo${NC}"
else
    echo -e "  SMTP:               ${YELLOW}No activo${NC}"
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Preguntar si desea continuar con el despliegue (Solo si NO es modo auto)
if [ "$AUTO_MODE" = false ]; then
    read -p "¿Deseas iniciar el despliegue ahora? (y/n) [y]: " START_DEPLOYMENT
    START_DEPLOYMENT=${START_DEPLOYMENT:-y}
else
    START_DEPLOYMENT="y"
fi

if [[ ! "$START_DEPLOYMENT" =~ ^[Yy]$ ]]; then
    print_warning "Despliegue cancelado. Puedes ejecutarlo manualmente con: docker-compose up -d"
    exit 0
fi

# Validar configuración de Docker Compose
print_info "Validando configuración de Docker Compose..."
if docker-compose config > /dev/null 2>&1; then
    print_success "Configuración de Docker Compose válida"
else
    print_error "Configuración de Docker Compose inválida. Ejecuta 'docker-compose config' para ver detalles."
    exit 1
fi

# =============================================================================
# ETAPA 6: DESPLIEGUE DE SERVICIOS
# =============================================================================

echo ""
print_info "Iniciando despliegue del stack..."
echo ""

# Detener servicios existentes si los hay
if [ "$(docker ps -q -f name=opensearch)" ]; then
    print_info "Deteniendo servicios existentes..."
    docker-compose down
fi

# Levantar servicios
print_info "Levantando servicios con docker-compose..."
docker-compose up -d

# Esperar a que los servicios estén listos
print_info "Esperando a que los servicios estén listos (esto puede tardar 30-60 segundos)..."
sleep 30

# =============================================================================
# ETAPA 7: VERIFICACIÓN DE SERVICIOS
# =============================================================================

print_info "Verificando servicios..."
echo ""

# Verificar OpenSearch Cluster
print_info "Verificando cluster OpenSearch..."
for i in {1..10}; do
    if curl -s --max-time 5 http://localhost:9200/_cluster/health &> /dev/null; then
        CLUSTER_HEALTH=$(curl -s --max-time 5 http://localhost:9200/_cluster/health | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        print_success "Cluster OpenSearch está corriendo (Status: ${CLUSTER_HEALTH})"
        break
    else
        if [ $i -eq 10 ]; then
            print_warning "No se pudo conectar al cluster OpenSearch en localhost:9200"
        else
            sleep 5
        fi
    fi
done

# Verificar contenedores
print_info "Estado de los contenedores:"
docker-compose ps

# =============================================================================
# ETAPA 8: FINALIZACIÓN
# =============================================================================

echo -e "${GREEN}║           ✓ DESPLIEGUE COMPLETADO CON ÉXITO              ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

print_info "URLs de acceso:"
echo -e "  ${BLUE}•${NC} Grafana:              http://${INFRA_SERVER_IP}:3000"
echo -e "  ${BLUE}•${NC} Prometheus:           http://${INFRA_SERVER_IP}:9090"
echo -e "  ${BLUE}•${NC} OpenSearch Dashboards: http://${INFRA_SERVER_IP}:5601"
echo -e "  ${BLUE}•${NC} OpenSearch API:       http://${INFRA_SERVER_IP}:9200"
echo ""

print_info "Credenciales por defecto:"
echo -e "  ${BLUE}•${NC} Grafana:     admin / admin (cambiar al primer login)"
echo -e "  ${BLUE}•${NC} OpenSearch:  admin / ${OPENSEARCH_ADMIN_PASSWORD}"
echo ""

print_info "Comandos útiles:"
echo -e "  ${BLUE}•${NC} Ver logs:              docker-compose logs -f"
echo -e "  ${BLUE}•${NC} Detener servicios:     docker-compose down"
echo -e "  ${BLUE}•${NC} Reiniciar servicios:   docker-compose restart"
echo -e "  ${BLUE}•${NC} Ver salud del cluster: curl http://localhost:9200/_cluster/health?pretty"
echo ""

print_success "¡Disfruta de tu stack de observabilidad con Alta Disponibilidad!"
