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
LOGIN_PATH=""
FILTER_USER=""
FILTER_DB=""
FILTER_TIME=""
LOGGING_ENABLED=false
LOG_FILE=""
SCRIPT_NAME="mysql_locks_monitor"

# ==============================================================================
# Función de Ayuda (Usage)
# ==============================================================================
usage() {
    echo -e "${yel}Uso: $0 -l <login-path> [-t <delay>] [-u <users>] [-d <db>] [-m <secs>] [-o]${off}"
    echo -e "  -l  MySQL login-path (Requerido)"
    echo -e "  -t  Tiempo de refresco en segundos (Por defecto: 5)"
    echo -e "  -u  Filtrar por Usuario (Soporta lista separada por comas)"
    echo -e "  -d  Filtrar por Base de Datos (Esquema de la tabla bloqueada)"
    echo -e "  -m  Filtrar por Tiempo Mínimo de bloqueo en segundos (Ej: 10)"
    echo -e "  -o  Activar guardado automático en log desde el inicio"
    exit 1
}

# ==============================================================================
# Parseo de Parámetros
# ==============================================================================
while getopts "l:t:u:d:m:o" opt; do
    case ${opt} in
        l ) LOGIN_PATH="$OPTARG" ;;
        t ) DELAY="$OPTARG" ;;
        u ) FILTER_USER="$OPTARG" ;;
        d ) FILTER_DB="$OPTARG" ;;
        m ) FILTER_TIME="$OPTARG" ;;
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
# Inicialización y Detección
# ==============================================================================
echo -e "${cyn}Conectando a MySQL y verificando esquema SYS...${off}"
MYSQL_FULL_VER=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -N -e "SELECT VERSION();" 2>/dev/null)

if [[ -z "$MYSQL_FULL_VER" ]]; then
    echo -e "${red}[ERROR] No se pudo conectar a MySQL. Revisa tus credenciales.${off}"
    exit 1
fi

MYSQL_VER=$(echo "$MYSQL_FULL_VER" | awk -F'.' '{print $1"."$2}')

if [[ "$LOGGING_ENABLED" == true ]]; then
    LOG_FILE="${SCRIPT_NAME}_$(date +'%Y%m%d%S').log"
fi

tput civis 
PLAIN_FILE=$(mktemp /tmp/mysql_locks_plain.XXXXXX)
trap 'tput cvvis; rm -f "$PLAIN_FILE"; clear; echo -e "\n${yel}Monitorización de bloqueos finalizada.${off}"; exit 0' SIGINT SIGTERM

# ==============================================================================
# Bucle Interactivo Principal
# ==============================================================================
while true; do
    # --------------------------------------------------------------------------
    # 1. Configurar Filtros Dinámicos
    # --------------------------------------------------------------------------
    WHERE_CLAUSE="1=1"
    if [[ -n "$FILTER_USER" ]]; then
        FORMATTED_USERS=$(echo "$FILTER_USER" | tr -d ' ' | sed "s/,/','/g")
        WHERE_CLAUSE="${WHERE_CLAUSE} AND (pb.USER IN ('${FORMATTED_USERS}') OR pw.USER IN ('${FORMATTED_USERS}'))"
    fi
    if [[ -n "$FILTER_DB" ]]; then
        WHERE_CLAUSE="${WHERE_CLAUSE} AND w.locked_table LIKE '${FILTER_DB}.%'"
    fi
    if [[ -n "$FILTER_TIME" && "$FILTER_TIME" =~ ^[0-9]+$ ]]; then
        # Solución TZ: Utilizamos pw.TIME (tiempo real de espera del hilo) en lugar de wait_age_secs
        WHERE_CLAUSE="${WHERE_CLAUSE} AND pw.TIME >= ${FILTER_TIME}"
    fi

    # --------------------------------------------------------------------------
    # 2. Query Maestra de Bloqueos (Blockers vs Waiters)
    # --------------------------------------------------------------------------
    MAIN_QUERY="
    SELECT 
        w.blocking_pid AS blk_id,
        COALESCE(pb.USER, '-') AS blk_user,
        w.waiting_pid AS wait_id,
        COALESCE(pw.USER, '-') AS wait_user,
        COALESCE(w.locked_table, '-') AS locked_obj,
        COALESCE(pw.TIME, 0) AS wait_time,
        COALESCE(NULLIF(SUBSTRING(REPLACE(REPLACE(REPLACE(w.blocking_query, '\n', ' '), '\r', ''), '\t', ' '), 1, 45), ''), '[Inactiva/Sleep]') AS blk_query,
        COALESCE(NULLIF(SUBSTRING(REPLACE(REPLACE(REPLACE(w.waiting_query, '\n', ' '), '\r', ''), '\t', ' '), 1, 45), ''), '-') AS wait_query
    FROM sys.innodb_lock_waits w
    LEFT JOIN information_schema.PROCESSLIST pb ON w.blocking_pid = pb.ID
    LEFT JOIN information_schema.PROCESSLIST pw ON w.waiting_pid = pw.ID
    WHERE ${WHERE_CLAUSE}
    ORDER BY wait_time DESC;"

    TOTAL_QUERY="
    SELECT count(*) 
    FROM sys.innodb_lock_waits w
    LEFT JOIN information_schema.PROCESSLIST pb ON w.blocking_pid = pb.ID
    LEFT JOIN information_schema.PROCESSLIST pw ON w.waiting_pid = pw.ID
    WHERE ${WHERE_CLAUSE};"

    # --------------------------------------------------------------------------
    # 3. Ejecutar Consultas
    # --------------------------------------------------------------------------
    MAIN_DATA=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -e "$MAIN_QUERY" 2>&1)
    TOTAL_LOCKS=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -N -e "$TOTAL_QUERY" 2>&1)
    CURRENT_TIME=$(date +'%Y-%m-%d %H:%M:%S')

    # --------------------------------------------------------------------------
    # 4. Procesamiento y Alineación Estricta de la Tabla
    # --------------------------------------------------------------------------
    COLORIZED_OUT=$(echo "$MAIN_DATA" | awk -v plain_file="$PLAIN_FILE" '
    BEGIN {
        FS="\t"; OFS="\t"
        split("\033[32m \033[33m \033[34m \033[35m \033[36m \033[91m \033[92m \033[93m \033[94m \033[95m \033[96m", colors, " ")
        c_idx = 1
        reset = "\033[0m"
        red = "\033[0;31m"
        
        fmt = "%-8.8s | %-12.12s | %-8.8s | %-12.12s | %-25.25s | %-7.7s | %-45.45s | %-45.45s"
        header = sprintf(fmt, "BLK_ID", "BLK_USER", "WAIT_ID", "WAIT_USER", "LOCKED_OBJ", "TIME(s)", "BLOCKING_QUERY (El Culpable)", "WAITING_QUERY (La Víctima)")
        sep    = "---------+--------------+----------+--------------+---------------------------+---------+-----------------------------------------------+-----------------------------------------------"
        
        print header
        print sep
        print header > plain_file
        print sep > plain_file
    }
    NR>1 {
        gsub(/\r/, "", $0)
        b_id=$1; b_u=$2; w_id=$3; w_u=$4; obj=$5; t=$6; b_q=$7;
        w_q=$8; for(i=9; i<=NF; i++) w_q=w_q" "$i;
        
        if (obj != "-") {
            if (!(obj in cmap)) { cmap[obj] = colors[c_idx]; c_idx = (c_idx % 11) + 1 }
            c = cmap[obj]
        } else { c = reset }
        
        b_id_colored = red b_id c
        line = sprintf(fmt, b_id, b_u, w_id, w_u, obj, t, b_q, w_q)
        line_color = sprintf(fmt, b_id_colored, b_u, w_id, w_u, obj, t, b_q, w_q)
        
        print c line_color reset      
        print line > plain_file 
    }')
    
    # --------------------------------------------------------------------------
    # 5. Renderizado de Pantalla
    # --------------------------------------------------------------------------
    clear 
    echo -e "${cyn}=====================================================================================${off}"
    echo -e "${red}MySQL LOCKS Monitor${off} |  Host: ${mag}$(hostname)${off}  |  Time: ${grn}${CURRENT_TIME}${off}  |  Delay: ${DELAY}s"
    
    FILTERS_TXT="User: ${FILTER_USER:-ALL} | DB: ${FILTER_DB:-ALL} | Min Time: ${FILTER_TIME:-0}s"
    if [[ "$LOGGING_ENABLED" == true ]]; then
        echo -e "${yel}Filters -> $FILTERS_TXT${off}  |  ${grn}[LOG ON: $LOG_FILE]${off}"
    else
        echo -e "${yel}Filters -> $FILTERS_TXT${off}  |  ${red}[LOG OFF]${off}"
    fi
    echo -e "Active Lock Conflicts: ${red}${TOTAL_LOCKS}${off}  |  MySQL Ver: ${MYSQL_VER} (vía sys schema)"
    echo -e "${cyn}=====================================================================================${off}"

    if [[ "$TOTAL_LOCKS" -eq 0 ]]; then
        echo -e "\n${grn}No se detectan bloqueos (o no superan el filtro actual).${off}\n"
    else
        echo -e "$COLORIZED_OUT"
    fi

    # --------------------------------------------------------------------------
    # 6. Guardado en Log
    # --------------------------------------------------------------------------
    if [[ "$LOGGING_ENABLED" == true ]]; then
        {
            echo "====================================================================================="
            echo "Time: ${CURRENT_TIME} | Host: $(hostname) | MySQL Ver: ${MYSQL_FULL_VER}"
            echo "Filters -> $FILTERS_TXT"
            echo "Total Lock Conflicts: ${TOTAL_LOCKS}"
            echo "====================================================================================="
            cat "$PLAIN_FILE"
            echo -e "\n"
        } >> "$LOG_FILE"
    fi

    # --------------------------------------------------------------------------
    # 7. Menú Interactivo
    # --------------------------------------------------------------------------
    echo -e "\n${cyn}Interactive Commands:${off}"
    echo -e "  [u] User filter  |  [d] DB filter   |  [m] Min Time filter |  [c] Clear filters"
    echo -e "  [t] Change delay |  [l] Toggle Log  |  [r] Refresh now     |  ${red}[k] Kill Blocker${off}   |  [q] Quit"
    echo -n "Press key: "

    key=""
    read -t "$DELAY" -n 1 -s key

    case "$key" in
        q|Q) tput cvvis; clear; echo -e "${yel}Saliendo del monitor...${off}"; if [[ "$LOGGING_ENABLED" == true ]]; then echo -e "Log guardado en: ${grn}$LOG_FILE${off}"; fi; exit 0 ;;
        u|U) tput cvvis; echo -e "\n"; read -p "Introduce USUARIO(s) para filtrar (separados por comas): " FILTER_USER; tput civis ;;
        d|D) tput cvvis; echo -e "\n"; read -p "Introduce ESQUEMA/DB exacta para filtrar: " FILTER_DB; tput civis ;;
        m|M) tput cvvis; echo -e "\n"; read -p "Introduce tiempo mínimo de bloqueo (segs): " NEW_TIME; if [[ "$NEW_TIME" =~ ^[0-9]+$ ]]; then FILTER_TIME="$NEW_TIME"; else echo -e "${red}Valor inválido.${off}"; sleep 1; fi; tput civis ;;
        t|T) tput cvvis; echo -e "\n"; read -p "Introduce nuevo delay de refresco (segs): " NEW_DELAY; if [[ "$NEW_DELAY" =~ ^[0-9]+$ ]] && [ "$NEW_DELAY" -gt 0 ]; then DELAY="$NEW_DELAY"; fi; tput civis ;;
        l|L) tput cvvis; if [[ "$LOGGING_ENABLED" == true ]]; then LOGGING_ENABLED=false; echo -e "\n${yel}Grabación de Log pausada.${off}"; else LOGGING_ENABLED=true; LOG_FILE="${SCRIPT_NAME}_$(date +'%Y%m%d%S').log"; echo -e "\n${grn}Grabación de Log habilitada. Escribiendo en: $LOG_FILE${off}"; fi; sleep 1.5; tput civis ;;
        k|K) tput cvvis; echo -e "\n"; read -p "Introduce el ID a liquidar (Suele ser el BLK_ID): " KILL_ID; if [[ "$KILL_ID" =~ ^[0-9]+$ ]]; then read -p "¿Seguro que deseas liquidar la conexión $KILL_ID? [y/N]: " CONFIRM; if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then KILL_RES=$($MYSQLBIN --login-path="${LOGIN_PATH}" -e "KILL $KILL_ID;" 2>&1); if [[ $? -eq 0 ]]; then echo -e "${grn}[OK] Conexión $KILL_ID fulminada con éxito.${off}"; else echo -e "${red}[ERROR] No se pudo matar el hilo $KILL_ID: $KILL_RES${off}"; fi; else echo -e "${yel}Operación de KILL cancelada.${off}"; fi; else if [[ -n "$KILL_ID" ]]; then echo -e "${red}[ERROR] ID numérico requerido.${off}"; fi; fi; sleep 2; tput civis ;;
        c|C) FILTER_USER=""; FILTER_DB=""; FILTER_TIME="" ;;
    esac
done