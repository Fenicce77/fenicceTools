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
MIN_TIME=1
LOGIN_PATH=""
FILTER_USER=""
FILTER_DB=""
FILTER_HOST=""
LOGGING_ENABLED=false
LOG_FILE=""
SCRIPT_NAME=$(basename "$0")

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
# Autodetección de Versión MySQL
# ==============================================================================
echo -e "${cyn}Conectando y detectando versión de MySQL...${off}"
MYSQL_FULL_VER=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -N -e "SELECT VERSION();" 2>/dev/null)

if [[ -z "$MYSQL_FULL_VER" ]]; then
    echo -e "${red}[ERROR] No se pudo conectar a MySQL con el login-path '${LOGIN_PATH}'. Revisa tus credenciales.${off}"
    exit 1
fi

MYSQL_VER=$(echo "$MYSQL_FULL_VER" | awk -F'.' '{print $1"."$2}')
echo -e "${grn}Versión detectada: ${MYSQL_FULL_VER} (Dialecto a usar: ${MYSQL_VER})${off}"
sleep 1.5

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
    # 1. Configurar Campos y Query Según Versión
    # --------------------------------------------------------------------------
    if [[ "$MYSQL_VER" == "5.7" ]]; then
        U_FIELD="p.USER"
        D_FIELD="p.DB"
        H_FIELD="p.HOST"
        
        WHERE_CLAUSE="${U_FIELD} NOT IN (${EXCLUDED_USERS})"
        [[ -n "$FILTER_USER" ]] && WHERE_CLAUSE="${WHERE_CLAUSE} AND ${U_FIELD} = '${FILTER_USER}'"
        [[ -n "$FILTER_DB" ]]   && WHERE_CLAUSE="${WHERE_CLAUSE} AND ${D_FIELD} = '${FILTER_DB}'"
        [[ -n "$FILTER_HOST" ]] && WHERE_CLAUSE="${WHERE_CLAUSE} AND ${H_FIELD} LIKE '%${FILTER_HOST}%'"

        # AÑADIDO: p.USER AS user,
        MAIN_QUERY="
        SELECT p.ID AS conn_id, p.USER AS user, COALESCE(p.DB, '-') AS db, COALESCE(t.trx_id, e.EVENT_ID, '-') AS trx_q_id,
            GREATEST(p.TIME, COALESCE(TIMESTAMPDIFF(SECOND, t.trx_started, NOW()), 0)) AS exec_time,
            DATE_FORMAT(COALESCE(t.trx_started, DATE_SUB(NOW(), INTERVAL p.TIME SECOND)), '%Y-%m-%d %H:%i:%s') AS start_time,
            COALESCE(e.DIGEST, '-') AS query_hash,
            COALESCE(SUBSTRING(REPLACE(REPLACE(p.INFO, '\n', ' '), '\r', ''), 1, 50), '-') AS query_text
        FROM information_schema.PROCESSLIST p
        LEFT JOIN information_schema.innodb_trx t ON p.ID = t.trx_mysql_thread_id
        LEFT JOIN performance_schema.threads th ON p.ID = th.PROCESSLIST_ID
        LEFT JOIN performance_schema.events_statements_current e ON th.THREAD_ID = e.THREAD_ID
        WHERE ${WHERE_CLAUSE} AND p.ID != CONNECTION_ID() AND (p.COMMAND != 'Sleep' OR t.trx_id IS NOT NULL)
          AND GREATEST(p.TIME, COALESCE(TIMESTAMPDIFF(SECOND, t.trx_started, NOW()), 0)) >= ${MIN_TIME}
        ORDER BY exec_time DESC;"

        TOTAL_QUERY="SELECT count(*) FROM information_schema.PROCESSLIST p 
        LEFT JOIN information_schema.innodb_trx t ON p.ID = t.trx_mysql_thread_id 
        WHERE ${WHERE_CLAUSE} AND p.ID != CONNECTION_ID() AND (p.COMMAND != 'Sleep' OR t.trx_id IS NOT NULL)
          AND GREATEST(p.TIME, COALESCE(TIMESTAMPDIFF(SECOND, t.trx_started, NOW()), 0)) >= ${MIN_TIME};"

    else
        U_FIELD="th.PROCESSLIST_USER"
        D_FIELD="th.PROCESSLIST_DB"
        H_FIELD="th.PROCESSLIST_HOST"
        
        WHERE_CLAUSE="${U_FIELD} NOT IN (${EXCLUDED_USERS})"
        [[ -n "$FILTER_USER" ]] && WHERE_CLAUSE="${WHERE_CLAUSE} AND ${U_FIELD} = '${FILTER_USER}'"
        [[ -n "$FILTER_DB" ]]   && WHERE_CLAUSE="${WHERE_CLAUSE} AND ${D_FIELD} = '${FILTER_DB}'"
        [[ -n "$FILTER_HOST" ]] && WHERE_CLAUSE="${WHERE_CLAUSE} AND ${H_FIELD} LIKE '%${FILTER_HOST}%'"

        # AÑADIDO: th.PROCESSLIST_USER AS user,
        MAIN_QUERY="
        SELECT th.PROCESSLIST_ID AS conn_id, th.PROCESSLIST_USER AS user, COALESCE(th.PROCESSLIST_DB, '-') AS db, COALESCE(t.trx_id, e.EVENT_ID, '-') AS trx_q_id,
            GREATEST(th.PROCESSLIST_TIME, COALESCE(TIMESTAMPDIFF(SECOND, t.trx_started, NOW()), 0)) AS exec_time,
            DATE_FORMAT(COALESCE(t.trx_started, DATE_SUB(NOW(), INTERVAL th.PROCESSLIST_TIME SECOND)), '%Y-%m-%d %H:%i:%s') AS start_time,
            COALESCE(e.DIGEST, '-') AS query_hash,
            COALESCE(SUBSTRING(REPLACE(REPLACE(th.PROCESSLIST_INFO, '\n', ' '), '\r', ''), 1, 50), '-') AS query_text
        FROM performance_schema.threads th
        LEFT JOIN information_schema.innodb_trx t ON th.PROCESSLIST_ID = t.trx_mysql_thread_id
        LEFT JOIN performance_schema.events_statements_current e ON th.THREAD_ID = e.THREAD_ID
        WHERE ${WHERE_CLAUSE} AND th.PROCESSLIST_ID != CONNECTION_ID() AND (th.PROCESSLIST_COMMAND != 'Sleep' OR t.trx_id IS NOT NULL)
          AND GREATEST(th.PROCESSLIST_TIME, COALESCE(TIMESTAMPDIFF(SECOND, t.trx_started, NOW()), 0)) >= ${MIN_TIME}
        ORDER BY exec_time DESC;"

        TOTAL_QUERY="SELECT count(*) FROM performance_schema.threads th 
        LEFT JOIN information_schema.innodb_trx t ON th.PROCESSLIST_ID = t.trx_mysql_thread_id 
        WHERE ${WHERE_CLAUSE} AND th.PROCESSLIST_ID != CONNECTION_ID() AND (th.PROCESSLIST_COMMAND != 'Sleep' OR t.trx_id IS NOT NULL)
          AND GREATEST(th.PROCESSLIST_TIME, COALESCE(TIMESTAMPDIFF(SECOND, t.trx_started, NOW()), 0)) >= ${MIN_TIME};"
    fi

    # --------------------------------------------------------------------------
    # 2. Ejecutar Consultas
    # --------------------------------------------------------------------------
    MAIN_DATA=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -e "$MAIN_QUERY" 2>&1)
    TOTAL_CONNECTIONS=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -N -e "$TOTAL_QUERY" 2>&1)
    CURRENT_TIME=$(date +'%Y-%m-%d %H:%M:%S')

    # --------------------------------------------------------------------------
    # 3. Procesamiento y Alineación Estricta de la Tabla
    # --------------------------------------------------------------------------
    COLORIZED_OUT=$(echo "$MAIN_DATA" | awk -v plain_file="$PLAIN_FILE" '
    BEGIN {
        FS="\t"
        OFS="\t"
        split("\033[32m \033[33m \033[34m \033[35m \033[36m \033[91m \033[92m \033[93m \033[94m \033[95m \033[96m", colors, " ")
        c_idx = 1
        reset = "\033[0m"
        
        # AÑADIDO: %-25.25s para el USER
        fmt = "%-10.10s | %-25.25s | %-15.15s | %-15.15s | %-7.7s | %-19.19s | %-64.64s | %-50.50s"
        header = sprintf(fmt, "CONN_ID", "USER", "DB", "TRX/Q_ID", "TIME(s)", "START_TIME", "QUERY_HASH", "QUERY_TEXT")
        sep    = "-----------+---------------------------+-----------------+-----------------+---------+---------------------+------------------------------------------------------------------+---------------------------------------------------"
        
        print header
        print sep
        print header > plain_file
        print sep > plain_file
    }
    NR>1 {
        gsub(/\r/, "", $0)
        id=$1; u=$2; db=$3; tr=$4; t=$5; st=$6; h=$7; q=$8;
        
        if (db != "-") {
            if (!(db in cmap)) {
                cmap[db] = colors[c_idx]
                c_idx = (c_idx % 11) + 1
            }
            c = cmap[db]
        } else {
            c = reset
        }
        
        line = sprintf(fmt, id, u, db, tr, t, st, h, q)
        print c line reset      
        print line > plain_file 
    }')
    
    # --------------------------------------------------------------------------
    # 4. Renderizado de Pantalla
    # --------------------------------------------------------------------------
    clear 
    echo -e "${cyn}=====================================================================================${off}"
    echo -e "MySQL Queries Monitor |  Host: ${mag}$(hostname)${off}  |  Time: ${grn}${CURRENT_TIME}${off}  |  Delay: ${DELAY}s"
    
    if [[ "$LOGGING_ENABLED" == true ]]; then
        echo -e "${yel}Filters -> User: ${FILTER_USER:-ALL} | DB: ${FILTER_DB:-ALL} | Host: ${FILTER_HOST:-ALL}${off}  |  ${grn}[LOG ON: $LOG_FILE]${off}"
    else
        echo -e "${yel}Filters -> User: ${FILTER_USER:-ALL} | DB: ${FILTER_DB:-ALL} | Host: ${FILTER_HOST:-ALL}${off}  |  ${red}[LOG OFF]${off}"
    fi
    echo -e "Slow Queries/Trx (> ${yel}${MIN_TIME}s${off}) Filtered: ${grn}${TOTAL_CONNECTIONS}${off}  |  MySQL Ver: ${MYSQL_VER}"
    echo -e "${cyn}=====================================================================================${off}"

    echo -e "$COLORIZED_OUT"

    # --------------------------------------------------------------------------
    # 5. Guardado en Log
    # --------------------------------------------------------------------------
    if [[ "$LOGGING_ENABLED" == true ]]; then
        {
            echo "====================================================================================="
            echo "Time: ${CURRENT_TIME} | Host: $(hostname) | MySQL Ver: ${MYSQL_FULL_VER}"
            echo "Filters -> User: ${FILTER_USER:-ALL} | DB: ${FILTER_DB:-ALL} | Host: ${FILTER_HOST:-ALL} | Min Time: ${MIN_TIME}s"
            echo "Total Slow Queries: ${TOTAL_CONNECTIONS}"
            echo "====================================================================================="
            cat "$PLAIN_FILE"
            echo -e "\n"
        } >> "$LOG_FILE"
    fi

    # --------------------------------------------------------------------------
    # 6. Menú Interactivo
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