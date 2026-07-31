#!/bin/bash

# ==============================================================================
# Configuración de Colores para la salida en terminal
# ==============================================================================
red='\033[0;31m'
grn='\033[0;32m'
yel='\033[0;33m'
mag='\033[0;35m'
cyn='\033[0;36m'
off='\033[0m'

# ==============================================================================
# Variables por Defecto
# ==============================================================================
DELAY=5
MIN_TIME=10
LOGIN_PATH=""
FILTER_USER=""
FILTER_DB=""
FILTER_HOST=""
LOGGING_ENABLED=false
LOG_FILE=""
SCRIPT_NAME=$(basename "$0")
PREV_HLL="" # Variable para guardar el estado del HLL del ciclo anterior

# ==============================================================================
# Función de Ayuda (Usage)
# ==============================================================================
usage() {
    echo -e "${yel}Uso: $0 -l <login-path> [-t <delay>] [-m <min_secs>] [-u <user>] [-d <db>] [-h <host>] [-o]${off}"
    echo -e "  -l  MySQL login-path (Requerido)"
    echo -e "  -t  Tiempo de refresco en segundos (Por defecto: 5)"
    echo -e "  -m  Tiempo mínimo de ejecución en segs para filtrar (Por defecto: 10)"
    echo -e "  -u  Filtrar por Usuario"
    echo -e "  -d  Filtrar por Base de Datos"
    echo -e "  -h  Filtrar por Host IP/Nombre"
    echo -e "  -o  Activar guardado automático en log desde el inicio"
    exit 1
}

# ==============================================================================
# Parseo de Parámetros
# ==============================================================================
while getopts "l:t:m:u:d:h:o" opt; do
    case ${opt} in
        l ) LOGIN_PATH="$OPTARG" ;;
        t ) DELAY="$OPTARG" ;;
        m ) MIN_TIME="$OPTARG" ;;
        u ) FILTER_USER="$OPTARG" ;;
        d ) FILTER_DB="$OPTARG" ;;
        h ) FILTER_HOST="$OPTARG" ;;
        o ) LOGGING_ENABLED=true ;;
        \? ) usage ;;
    esac
done

if [[ -z "$LOGIN_PATH" ]]; then
    echo -e "${red}[ERROR] Falta el parámetro de conexión (-l login-path).${off}\n"
    usage
fi

MYSQLBIN=$(command -v mysql)
if [[ -z "$MYSQLBIN" ]]; then
    echo -e "${red}[ERROR] Binario de MySQL no encontrado en el sistema.${off}"
    exit 1
fi

# ==============================================================================
# Detección de Versión MySQL (Para contexto en Log)
# ==============================================================================
echo -e "${cyn}Conectando a MySQL...${off}"
MYSQL_FULL_VER=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -N -e "SELECT VERSION();" 2>/dev/null)

if [[ -z "$MYSQL_FULL_VER" ]]; then
    echo -e "${red}[ERROR] No se pudo conectar a MySQL con el login-path '${LOGIN_PATH}'. Revisa tus credenciales.${off}"
    exit 1
fi

MYSQL_VER=$(echo "$MYSQL_FULL_VER" | awk -F'.' '{print $1"."$2}')
sleep 0.5

if [[ "$LOGGING_ENABLED" == true ]]; then
    LOG_FILE="${SCRIPT_NAME}_$(date +'%Y%m%d%S').log"
fi

# ==============================================================================
# Gestión de la Terminal y Limpieza
# ==============================================================================
tput civis 
PLAIN_FILE=$(mktemp /tmp/mysql_monitor_plain.XXXXXX)
trap 'tput cvvis; rm -f "$PLAIN_FILE"; clear; echo -e "\n${yel}Monitorización finalizada.${off}"; exit 0' SIGINT SIGTERM

EXCLUDED_USERS="'root','gsancliment','pmm_monitor','proxysql-monitor','coms_rpl_gh_primary','cloudsqlreplica','devel-migration-job','event_scheduler'"

# ==============================================================================
# Bucle Interactivo Principal
# ==============================================================================
while true; do
    # --------------------------------------------------------------------------
    # 1. Configurar Filtros (Híbridos)
    # --------------------------------------------------------------------------
    WHERE_CLAUSE="COALESCE(th.PROCESSLIST_USER, p.USER) NOT IN (${EXCLUDED_USERS})"
    [[ -n "$FILTER_USER" ]] && WHERE_CLAUSE="${WHERE_CLAUSE} AND COALESCE(th.PROCESSLIST_USER, p.USER) = '${FILTER_USER}'"
    [[ -n "$FILTER_DB" ]]   && WHERE_CLAUSE="${WHERE_CLAUSE} AND COALESCE(th.PROCESSLIST_DB, p.DB) = '${FILTER_DB}'"
    [[ -n "$FILTER_HOST" ]] && WHERE_CLAUSE="${WHERE_CLAUSE} AND COALESCE(th.PROCESSLIST_HOST, p.HOST) LIKE '%${FILTER_HOST}%'"

    # --------------------------------------------------------------------------
    # 2. Consultas (Queries + Metadatos)
    # --------------------------------------------------------------------------
    # History List Length
    HLL_QUERY="SELECT count FROM information_schema.innodb_metrics WHERE name = 'trx_rseg_history_len';"
    CURRENT_HLL=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -N -e "$HLL_QUERY" 2>/dev/null)
    
    # Manejo seguro si la métrica está deshabilitada (fallback a 0)
    if [[ -z "$CURRENT_HLL" ]]; then CURRENT_HLL=0; fi

    # Tabla Principal Híbrida
    MAIN_QUERY="
    SELECT 
        p.ID AS conn_id, 
        COALESCE(th.PROCESSLIST_USER, p.USER) AS user, 
        COALESCE(th.PROCESSLIST_DB, p.DB, '-') AS db, 
        COALESCE(NULLIF(th.PROCESSLIST_STATE, ''), NULLIF(p.STATE, ''), th.PROCESSLIST_COMMAND, p.COMMAND, '-') AS thread_state,
        COALESCE(t.trx_id, e.EVENT_ID, '-') AS trx_q_id,
        GREATEST(COALESCE(th.PROCESSLIST_TIME, p.TIME, 0), COALESCE(TIMESTAMPDIFF(SECOND, t.trx_started, NOW()), 0)) AS exec_time,
        DATE_FORMAT(COALESCE(t.trx_started, DATE_SUB(NOW(), INTERVAL COALESCE(th.PROCESSLIST_TIME, p.TIME, 0) SECOND)), '%Y-%m-%d %H:%i:%s') AS start_time,
        COALESCE(
            NULLIF(e.DIGEST, ''), 
            IF(COALESCE(th.PROCESSLIST_COMMAND, p.COMMAND) != 'Sleep' AND COALESCE(e.SQL_TEXT, p.INFO) IS NOT NULL, SHA2(COALESCE(e.SQL_TEXT, p.INFO), 256), NULL),
            '-'
        ) AS query_hash,
        COALESCE(
            IF(COALESCE(th.PROCESSLIST_COMMAND, p.COMMAND) = 'Sleep', IF(t.trx_id IS NOT NULL, '[Transacción Inactiva]', '-'), NULL),
            NULLIF(SUBSTRING(REPLACE(REPLACE(REPLACE(e.SQL_TEXT, '\n', ' '), '\r', ''), '\t', ' '), 1, 50), ''),
            NULLIF(SUBSTRING(REPLACE(REPLACE(REPLACE(p.INFO, '\n', ' '), '\r', ''), '\t', ' '), 1, 50), ''),
            '-'
        ) AS query_text
    FROM information_schema.PROCESSLIST p
    LEFT JOIN performance_schema.threads th ON p.ID = th.PROCESSLIST_ID
    LEFT JOIN information_schema.innodb_trx t ON p.ID = t.trx_mysql_thread_id
    LEFT JOIN performance_schema.events_statements_current e ON th.THREAD_ID = e.THREAD_ID
    WHERE ${WHERE_CLAUSE} 
      AND p.ID != CONNECTION_ID() 
      AND (COALESCE(th.PROCESSLIST_COMMAND, p.COMMAND) != 'Sleep' OR t.trx_id IS NOT NULL)
      AND GREATEST(COALESCE(th.PROCESSLIST_TIME, p.TIME, 0), COALESCE(TIMESTAMPDIFF(SECOND, t.trx_started, NOW()), 0)) >= ${MIN_TIME}
    ORDER BY exec_time DESC;"

    TOTAL_QUERY="
    SELECT count(*) 
    FROM information_schema.PROCESSLIST p 
    LEFT JOIN performance_schema.threads th ON p.ID = th.PROCESSLIST_ID
    LEFT JOIN information_schema.innodb_trx t ON p.ID = t.trx_mysql_thread_id 
    WHERE ${WHERE_CLAUSE} 
      AND p.ID != CONNECTION_ID() 
      AND (COALESCE(th.PROCESSLIST_COMMAND, p.COMMAND) != 'Sleep' OR t.trx_id IS NOT NULL)
      AND GREATEST(COALESCE(th.PROCESSLIST_TIME, p.TIME, 0), COALESCE(TIMESTAMPDIFF(SECOND, t.trx_started, NOW()), 0)) >= ${MIN_TIME};"

    # --------------------------------------------------------------------------
    # 3. Ejecutar y Procesar Datos
    # --------------------------------------------------------------------------
    MAIN_DATA=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -e "$MAIN_QUERY" 2>&1)
    TOTAL_CONNECTIONS=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -N -e "$TOTAL_QUERY" 2>&1)
    CURRENT_TIME=$(date +'%Y-%m-%d %H:%M:%S')

    # Lógica de Cálculo y Color del HLL
    if [[ -z "$PREV_HLL" ]]; then
        HLL_DIFF_STR="0"
    else
        HLL_DIFF=$((CURRENT_HLL - PREV_HLL))
        if (( HLL_DIFF > 0 )); then
            HLL_DIFF_STR="+${HLL_DIFF}"
        elif (( HLL_DIFF < 0 )); then
            HLL_DIFF_STR="${HLL_DIFF}"
        else
            HLL_DIFF_STR="0"
        fi
    fi
    PREV_HLL=$CURRENT_HLL

    # Aplicación de Umbrales de Color
    if (( CURRENT_HLL >= 500000 )); then
        HLL_COLOR=$red
    elif (( CURRENT_HLL >= 100000 )); then
        HLL_COLOR=$yel
    else
        HLL_COLOR=$grn
    fi

    # --------------------------------------------------------------------------
    # 4. Procesamiento y Alineación Estricta de la Tabla
    # --------------------------------------------------------------------------
    COLORIZED_OUT=$(echo "$MAIN_DATA" | awk -v plain_file="$PLAIN_FILE" '
    BEGIN {
        FS="\t"
        OFS="\t"
        split("\033[32m \033[33m \033[34m \033[35m \033[36m \033[91m \033[92m \033[93m \033[94m \033[95m \033[96m", colors, " ")
        c_idx = 1
        reset = "\033[0m"
        
        fmt = "%-10.10s | %-16.16s | %-15.15s | %-20.20s | %-15.15s | %-7.7s | %-19.19s | %-64.64s | %-50.50s"
        header = sprintf(fmt, "CONN_ID", "USER", "DB", "STATE", "TRX/Q_ID", "TIME(s)", "START_TIME", "QUERY_HASH", "QUERY_TEXT")
        sep    = "-----------+------------------+-----------------+----------------------+-----------------+---------+---------------------+------------------------------------------------------------------+---------------------------------------------------"
        
        print header
        print sep
        print header > plain_file
        print sep > plain_file
    }
    NR>1 {
        gsub(/\r/, "", $0)
        id=$1; u=$2; db=$3; st_field=$4; tr=$5; t=$6; st=$7; h=$8; 
        
        q=$9;
        for(i=10; i<=NF; i++) q=q" "$i;
        
        if (db != "-") {
            if (!(db in cmap)) {
                cmap[db] = colors[c_idx]
                c_idx = (c_idx % 11) + 1
            }
            c = cmap[db]
        } else {
            c = reset
        }
        
        line = sprintf(fmt, id, u, db, st_field, tr, t, st, h, q)
        print c line reset      
        print line > plain_file 
    }')
    
    # --------------------------------------------------------------------------
    # 5. Renderizado de Pantalla
    # --------------------------------------------------------------------------
    clear 
    echo -e "${cyn}=====================================================================================${off}"
    echo -e "MySQL Queries Monitor |  Host: ${mag}$(hostname)${off}  |  Time: ${grn}${CURRENT_TIME}${off}  |  Delay: ${DELAY}s"
    
    if [[ "$LOGGING_ENABLED" == true ]]; then
        echo -e "${yel}Filters -> User: ${FILTER_USER:-ALL} | DB: ${FILTER_DB:-ALL} | Host: ${FILTER_HOST:-ALL}${off}  |  ${grn}[LOG ON: $LOG_FILE]${off}"
    else
        echo -e "${yel}Filters -> User: ${FILTER_USER:-ALL} | DB: ${FILTER_DB:-ALL} | Host: ${FILTER_HOST:-ALL}${off}  |  ${red}[LOG OFF]${off}"
    fi
    echo -e "Slow Queries/Trx (> ${yel}${MIN_TIME}s${off}) Filtered: ${grn}${TOTAL_CONNECTIONS}${off}  |  MySQL Ver: ${MYSQL_VER} (Hybrid Mode)"
    echo -e "InnoDB History List Length: ${HLL_COLOR}${CURRENT_HLL}${off} (Diff: ${HLL_COLOR}${HLL_DIFF_STR}${off})"
    echo -e "${cyn}=====================================================================================${off}"

    echo -e "$COLORIZED_OUT"

    # --------------------------------------------------------------------------
    # 6. Guardado en Log
    # --------------------------------------------------------------------------
    if [[ "$LOGGING_ENABLED" == true ]]; then
        {
            echo "====================================================================================="
            echo "Time: ${CURRENT_TIME} | Host: $(hostname) | MySQL Ver: ${MYSQL_FULL_VER}"
            echo "Filters -> User: ${FILTER_USER:-ALL} | DB: ${FILTER_DB:-ALL} | Host: ${FILTER_HOST:-ALL} | Min Time: ${MIN_TIME}s"
            echo "Total Slow Queries: ${TOTAL_CONNECTIONS}"
            echo "InnoDB History List Length: ${CURRENT_HLL} (Diff: ${HLL_DIFF_STR})"
            echo "====================================================================================="
            cat "$PLAIN_FILE"
            echo -e "\n"
        } >> "$LOG_FILE"
    fi

    # --------------------------------------------------------------------------
    # 7. Menú Interactivo
    # --------------------------------------------------------------------------
    echo -e "\n${cyn}Interactive Commands:${off}"
    echo -e "  [u] User filter  |  [d] DB filter   |  [h] Host filter   |  [c] Clear filters"
    echo -e "  [t] Change delay |  [m] Change Min Time (>Xs)            |  [l] Toggle Log"
    echo -e "  [r] Refresh now  |  [q] Quit"
    echo -n "Press key: "

    key=""
    read -t "$DELAY" -n 1 -s key

    case "$key" in
        q|Q)
            tput cvvis; clear; echo -e "${yel}Saliendo del monitor...${off}"
            if [[ "$LOGGING_ENABLED" == true ]]; then echo -e "Log guardado en: ${grn}$LOG_FILE${off}"; fi
            exit 0
            ;;
        u|U)
            tput cvvis; echo -e "\n"; read -p "Introduce USUARIO exacto para filtrar: " FILTER_USER; tput civis
            ;;
        d|D)
            tput cvvis; echo -e "\n"; read -p "Introduce DB exacta para filtrar: " FILTER_DB; tput civis
            ;;
        h|H)
            tput cvvis; echo -e "\n"; read -p "Introduce HOST (parcial) para filtrar: " FILTER_HOST; tput civis
            ;;
        t|T)
            tput cvvis; echo -e "\n"; read -p "Introduce nuevo delay de refresco (segs): " NEW_DELAY
            if [[ "$NEW_DELAY" =~ ^[0-9]+$ ]] && [ "$NEW_DELAY" -gt 0 ]; then DELAY="$NEW_DELAY"; fi
            tput civis
            ;;
        m|M)
            tput cvvis; echo -e "\n"; read -p "Introduce tiempo mínimo de query/trx en ejecución (segs): " NEW_MIN
            if [[ "$NEW_MIN" =~ ^[0-9]+$ ]]; then MIN_TIME="$NEW_MIN"; fi
            tput civis
            ;;
        l|L)
            tput cvvis
            if [[ "$LOGGING_ENABLED" == true ]]; then
                LOGGING_ENABLED=false; echo -e "\n${yel}Grabación de Log pausada.${off}"
            else
                LOGGING_ENABLED=true; LOG_FILE="${SCRIPT_NAME}_$(date +'%Y%m%d%S').log"
                echo -e "\n${grn}Grabación de Log habilitada. Escribiendo en: $LOG_FILE${off}"
            fi
            sleep 1.5; tput civis
            ;;
        c|C)
            FILTER_USER=""; FILTER_DB=""; FILTER_HOST=""
            ;;
    esac
done
