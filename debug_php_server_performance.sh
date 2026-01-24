#!/bin/bash

# ==============================================================================
# ADVANCED PHP-FPM ANALYZER (CentOS 7)
# ==============================================================================
# 1. Checks installed RPM version and OS.
# 2. Identifies top CPU consumers.
# 3. Calculates average Memory per PHP process.
# 4. Estimates Max Child capacity based on available RAM.
# 5. Checks PHP-FPM Pool Config (pm.max_children, slowlog).
# 6. Checks Redis Performance (Memory, Ops/sec, Evictions).
# 7. Checks Storage I/O Wait and Disk Usage.
# 8. Nginx Traffic Analysis (RPS & index.php breakdown) - DYNAMIC TIMEFRAME.
# 9. Checks Database Status (MySQL Slow Log & MongoDB).
# 10. Log Inspector (Reads PHP & MySQL logs automatically).
# 11. Attempts to fetch the Real-Time Status Page.
# ==============================================================================

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root (sudo)."
  exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}==============================================================================${NC}"
echo -e "${CYAN} PHP-FPM DEEP DIVE DIAGNOSTIC${NC}"
echo -e "${CYAN}==============================================================================${NC}"

# ------------------------------------------------------------------------------
# 1. PACKAGE & SYSTEM INFO
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[1] Package & System Information${NC}"

# Check OS
OS_NAME=$(cat /etc/centos-release 2>/dev/null || cat /etc/redhat-release 2>/dev/null || echo "Unknown OS")
echo "    OS: $OS_NAME"

# Check RPM Package
echo "    Installed RPMs:"
if command -v rpm &> /dev/null; then
    # Lists php-fpm packages with version and architecture
    RPM_INFO=$(rpm -qa --qf "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n" | grep php-fpm)
    if [ -z "$RPM_INFO" ]; then
        echo "    [!] No 'php-fpm' RPM found (might be compiled from source)."
    else
        echo "$RPM_INFO" | awk '{print "    - " $0}'
    fi
else
    echo "    [!] 'rpm' command not found."
fi

# Check Binary Version
echo "    Binary Version:"
if command -v php-fpm &> /dev/null; then
    php-fpm -v | head -n 1 | awk '{print "    - " $0}'
else
    echo "    [!] 'php-fpm' binary not found in PATH."
fi

# ------------------------------------------------------------------------------
# 2. PROCESS & CPU CHECK
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[2] CPU & Process Check${NC}"
PHP_PROC_COUNT=$(ps -C php-fpm --no-headers | wc -l)

if [ "$PHP_PROC_COUNT" -eq 0 ]; then
    echo -e "${RED}[!] No PHP-FPM processes found running.${NC}"
    echo "    Check service status: systemctl status php-fpm"
    exit 1
fi

# Calculate Total CPU used by all PHP-FPM processes
TOTAL_PHP_CPU=$(ps -C php-fpm --no-headers -o pcpu | awk '{sum+=$1} END {print sum}')

echo "    Active PHP-FPM Processes: $PHP_PROC_COUNT"
echo "    Total CPU Usage (all processes): ${TOTAL_PHP_CPU}%"

# Show top 3 CPU consumers
echo -e "\n    ${CYAN}Top 3 CPU-Consuming PHP Processes:${NC}"
ps -ylC php-fpm --sort:-pcpu | head -n 4 | awk '{printf "    PID: %-6s CPU: %-4s MEM: %-4s TIME: %-6s CMD: %s\n", $3, $4, $5, $14, $13}'

# ------------------------------------------------------------------------------
# 3. MEMORY USAGE & CAPACITY PLANNING
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[3] Memory Analysis & Capacity Planning${NC}"

# Calculate Total and Average Memory
# RSS (Resident Set Size) is roughly the physical memory used
MEM_STATS=$(ps --no-headers -o "rss" -C php-fpm | awk '{ sum+=$1 } END { if (NR > 0) print sum " " sum/NR; else print "0 0" }')
TOTAL_PHP_MEM_KB=$(echo "$MEM_STATS" | awk '{print $1}')
AVG_MEM_KB=$(echo "$MEM_STATS" | awk '{print $2}')

# Convert to MB
TOTAL_PHP_MEM_MB=$(echo "$TOTAL_PHP_MEM_KB / 1024" | bc)
AVG_MEM_MB=$(echo "$AVG_MEM_KB / 1024" | bc)

# Total System Memory
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
FREE_MEM_MB=$(free -m | awk '/^Mem:/{print $7}') # Available memory

echo "    System Total RAM:      ${TOTAL_MEM_MB} MB"
echo "    System Available RAM:  ${FREE_MEM_MB} MB"
echo "    Total RAM used by PHP: ${TOTAL_PHP_MEM_MB} MB"
echo "    Avg RAM per PHP Process: ~${AVG_MEM_MB} MB"

if [ "$AVG_MEM_MB" -gt 0 ]; then
    # Estimate safe max_children (leaving 500MB or 10% for OS/DB)
    RESERVED_MEM=500
    USABLE_MEM=$((TOTAL_MEM_MB - RESERVED_MEM))
    EST_MAX_CHILDREN=$((USABLE_MEM / AVG_MEM_MB))
    
    echo -e "    ${GREEN}Theoretical Max Children (based on total RAM): ~${EST_MAX_CHILDREN}${NC}"
else
    echo "    [!] Could not calculate average memory."
fi

# ------------------------------------------------------------------------------
# 4. CONFIGURATION INSPECTION
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[4] Configuration Inspection${NC}"

# Find likely config file (CentOS default or Remi)
CONF_FILE=$(find /etc/php-fpm.d /etc/opt/remi/*/php-fpm.d -name "www.conf" 2>/dev/null | head -n 1)
PHP_SLOWLOG=""

if [ -f "$CONF_FILE" ]; then
    echo "    Config File: $CONF_FILE"
    
    # Extract settings
    PM_MODE=$(grep "^pm =" "$CONF_FILE" | cut -d = -f 2 | xargs)
    MAX_CHILDREN=$(grep "^pm.max_children" "$CONF_FILE" | cut -d = -f 2 | xargs)
    START_SERVERS=$(grep "^pm.start_servers" "$CONF_FILE" | cut -d = -f 2 | xargs)
    STATUS_PATH=$(grep "^pm.status_path" "$CONF_FILE" | cut -d = -f 2 | xargs)
    LISTEN=$(grep "^listen =" "$CONF_FILE" | cut -d = -f 2 | xargs)
    
    # Capture slowlog path for later
    if grep -q "^slowlog" "$CONF_FILE"; then
        PHP_SLOWLOG=$(grep "^slowlog" "$CONF_FILE" | cut -d = -f 2 | xargs)
    fi

    echo "    ---------------------------------------------"
    echo "    Process Manager (pm):     ${PM_MODE:-dynamic (default)}"
    echo "    Max Children:             ${MAX_CHILDREN:-5}"
    echo "    Start Servers:            ${START_SERVERS:-2}"
    echo "    Listen Address:           ${LISTEN}"
    echo "    ---------------------------------------------"

    # Warning logic
    if [ "$PHP_PROC_COUNT" -ge "$MAX_CHILDREN" ]; then
        echo -e "    ${RED}[WARNING] Active processes ($PHP_PROC_COUNT) reached Max Children ($MAX_CHILDREN).${NC}"
        echo "              Requests are likely queuing. Consider increasing pm.max_children if RAM allows."
    elif [ "$EST_MAX_CHILDREN" -lt "$MAX_CHILDREN" ]; then
         echo -e "    ${YELLOW}[CAUTION] pm.max_children ($MAX_CHILDREN) is higher than estimated RAM capacity ($EST_MAX_CHILDREN).${NC}"
         echo "              Risk of OOM (Out of Memory) if traffic spikes."
    fi

else
    echo "    [!] Could not locate www.conf."
fi

# ------------------------------------------------------------------------------
# 5. REDIS PERFORMANCE SNAPSHOT
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[5] Redis Performance Snapshot${NC}"

# Define potential paths
CUSTOM_REDIS_PATH="/data/redis/bin/redis-cli"
REDIS_CMD=""

if [ -x "$CUSTOM_REDIS_PATH" ]; then
    REDIS_CMD="$CUSTOM_REDIS_PATH"
elif command -v redis-cli &> /dev/null; then
    REDIS_CMD="redis-cli"
fi

if [ -n "$REDIS_CMD" ]; then
    # Try to connect to default localhost:6379 without auth first
    REDIS_INFO=$(timeout 2s $REDIS_CMD info 2>/dev/null)

    if [ -z "$REDIS_INFO" ]; then
        echo "    [!] Could not connect to Redis (running? password protected?)."
        echo "        Try running: $REDIS_CMD info"
    else
        # Parse Metrics
        UPTIME=$(echo "$REDIS_INFO" | grep "uptime_in_days" | cut -d: -f2 | tr -d '\r')
        MEM_USED=$(echo "$REDIS_INFO" | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
        MEM_MAX=$(echo "$REDIS_INFO" | grep "maxmemory_human" | cut -d: -f2 | tr -d '\r')
        CLIENTS=$(echo "$REDIS_INFO" | grep "connected_clients" | cut -d: -f2 | tr -d '\r')
        OPS=$(echo "$REDIS_INFO" | grep "instantaneous_ops_per_sec" | cut -d: -f2 | tr -d '\r')
        EVICTED=$(echo "$REDIS_INFO" | grep "evicted_keys" | cut -d: -f2 | tr -d '\r')
        REJECTED=$(echo "$REDIS_INFO" | grep "rejected_connections" | cut -d: -f2 | tr -d '\r')

        echo "    Redis Uptime:          ${UPTIME} days"
        echo "    Memory Used:           ${MEM_USED} / ${MEM_MAX:-Unlimited}"
        echo "    Connected Clients:     ${CLIENTS}"
        echo "    Ops Per Second:        ${OPS}"
        echo "    ---------------------------------------------"

        # Analysis
        if [ "$EVICTED" -gt 0 ]; then
            echo -e "    ${YELLOW}[CAUTION] Evicted Keys: ${EVICTED}${NC}"
            echo "              Redis is running out of RAM and removing data."
        else
            echo "    Evicted Keys:          0 (Healthy)"
        fi

        if [ "$REJECTED" -gt 0 ]; then
            echo -e "    ${RED}[WARNING] Rejected Connections: ${REJECTED}${NC}"
            echo "              Hit maxclients limit. Increase 'maxclients' in redis.conf."
        else
            echo "    Rejected Conn:         0 (Healthy)"
        fi
    fi
else
    echo "    [i] 'redis-cli' not found in PATH or at $CUSTOM_REDIS_PATH."
fi

# ------------------------------------------------------------------------------
# 6. STORAGE & DISK I/O CHECK
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[6] Storage & Disk I/O Check${NC}"

# Check Disk Space
echo "    Disk Usage:"
df -h | grep -E '^/dev/' | head -n 3 | awk '{ print "    " $1 " : " $5 " used (" $4 " free)" }'

# Check IO Wait using vmstat
if command -v vmstat &> /dev/null; then
    echo "    Disk Wait (wa) Analysis (sampling 3s):"
    # Capture header and 3 samples
    vmstat 1 3 | tail -n 3 | awk '{ print "    CPU Idle: " $15 "% | IO Wait (wa): " $16 "%" }'
    
    # Check the last sample for high IO wait
    LAST_WA=$(vmstat 1 3 | tail -n 1 | awk '{print $16}')
    if [ "$LAST_WA" -gt 15 ]; then
        echo -e "    ${RED}[WARNING] High Disk I/O Wait detected ($LAST_WA%).${NC}"
        echo "              This often causes PHP-FPM to hang while waiting for files/DB."
    else
        echo "    Disk IO Wait:          OK"
    fi
else
    echo "    [i] 'vmstat' not found. Install 'sysstat' for detailed I/O stats."
fi

# ------------------------------------------------------------------------------
# 7. DATABASE HEALTH (MySQL & MongoDB)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[7] Database Checks${NC}"
SQ_FILE=""

# --- MySQL/MariaDB Check ---
if pgrep -x "mysqld" > /dev/null; then
    MYSQL_CPU=$(ps -C mysqld -o pcpu --no-headers | awk '{sum+=$1} END {print sum}')
    echo "    [MySQL/MariaDB] Running (CPU: ${MYSQL_CPU}%)"
    
    if command -v mysqladmin &> /dev/null; then
        # Try to get status without password (socket) or warn
        M_STATUS=$(timeout 2s mysqladmin status 2>/dev/null)
        if [ -n "$M_STATUS" ]; then
             echo "    $M_STATUS" | awk -F'  ' '{ for(i=1;i<=NF;i++) print "    - " $i }'
        else
             echo "    [!] Could not fetch 'mysqladmin status' (password required)."
        fi
    fi
    
    # Check Slow Query Log Status
    if command -v mysql &> /dev/null; then
        echo "    Checking Slow Query Log configuration..."
        # Try to fetch variables using mysql client
        VARS=$(timeout 2s mysql -N -B -e "SHOW VARIABLES WHERE Variable_name IN ('slow_query_log', 'slow_query_log_file', 'long_query_time');" 2>/dev/null)
        
        if [ -z "$VARS" ]; then
             echo "    [!] Could not fetch MySQL variables (Access denied or mysql down)."
        else
             SQ_STATUS=$(echo "$VARS" | awk '$1 == "slow_query_log" {print $2}')
             SQ_FILE=$(echo "$VARS" | awk '$1 == "slow_query_log_file" {print $2}')
             SQ_TIME=$(echo "$VARS" | awk '$1 == "long_query_time" {print $2}')

             if [ "$SQ_STATUS" == "ON" ]; then
                 echo -e "    Slow Query Log:        ${GREEN}ENABLED${NC}"
                 echo "    Log File:              $SQ_FILE"
                 echo "    Threshold:             ${SQ_TIME} seconds"
                 
                 # Check if threshold is too high (standard is 1 or 2)
                 if (( $(echo "$SQ_TIME >= 1.0" | bc -l) )); then
                     echo -e "    ${YELLOW}[TIP] Threshold is high ($SQ_TIME). Queries taking 0.1s-0.9s are ignored.${NC}"
                     echo "          Consider running: mysql -e \"SET GLOBAL long_query_time = 0.5;\""
                 fi
             else
                 echo -e "    Slow Query Log:        ${RED}DISABLED${NC}"
                 echo "    [i] To enable, add to /etc/my.cnf under [mysqld]:"
                 echo "        slow_query_log = 1"
                 echo "        slow_query_log_file = /var/log/mysql-slow.log"
                 echo "        long_query_time = 2"
                 echo "        (Then restart mysqld)"
             fi
        fi
    fi
else
    echo "    [MySQL/MariaDB] Not Running"
fi

echo ""

# --- MongoDB Check ---
if pgrep -x "mongod" > /dev/null; then
    MONGO_CPU=$(ps -C mongod -o pcpu --no-headers | awk '{sum+=$1} END {print sum}')
    echo "    [MongoDB]       Running (CPU: ${MONGO_CPU}%)"
    
    if command -v mongostat &> /dev/null; then
         # Try to get 1 second snapshot
         echo "    Snapshot (mongostat):"
         timeout 2s mongostat -n 1 --noheaders 2>/dev/null | head -n 1 | awk '{print "    Insert: "$1" | Query: "$2" | Update: "$3" | Delete: "$4" | Locked: "$16}'
    elif command -v mongo &> /dev/null; then
         # Fallback to mongo shell for status
         echo "    Checking connection..."
         timeout 2s mongo --eval "db.serverStatus().ok" --quiet 2>/dev/null | awk '{print "    Server Status OK: " $0}'
    else
         echo "    [i] 'mongostat' or 'mongo' tools not found."
    fi
else
    echo "    [MongoDB]       Not Running"
fi

# ------------------------------------------------------------------------------
# 8. NGINX TRAFFIC ANALYSIS
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[8] Nginx Traffic Analysis${NC}"

# Target Directory
NGINX_LOG_DIR="/var/www/efficiense/logs/nginx"

# Find access log files in that directory
LOG_FILES=$(find "$NGINX_LOG_DIR" -name "*.access.log" 2>/dev/null)

if [ -z "$LOG_FILES" ]; then
    echo "    [!] No '*.access.log' files found in $NGINX_LOG_DIR."
    echo "        Checking standard paths..."
    LOG_FILES=$(find /var/log/nginx /var/log/httpd -name "access.log" 2>/dev/null | head -n 1)
fi

if [ -n "$LOG_FILES" ]; then
    # 1. Ask user for timeframe
    read -p "    Enter analysis timeframe (e.g. 10m, 2h, 300) [default: 10m]: " TIME_INPUT
    TIME_INPUT=${TIME_INPUT:-10m}

    # 2. Normalize Input to full words for 'date' command
    CLEAN_TIME="$TIME_INPUT"
    if [[ "$TIME_INPUT" =~ ^[0-9]+$ ]]; then
        CLEAN_TIME="${TIME_INPUT} seconds"
        echo "    [i] Assuming '$TIME_INPUT' is seconds. Using: $CLEAN_TIME"
    elif [[ "$TIME_INPUT" =~ ^[0-9]+m$ ]]; then
        CLEAN_TIME="${TIME_INPUT//m/ minutes}"
    elif [[ "$TIME_INPUT" =~ ^[0-9]+h$ ]]; then
        CLEAN_TIME="${TIME_INPUT//h/ hours}"
    elif [[ "$TIME_INPUT" =~ ^[0-9]+d$ ]]; then
        CLEAN_TIME="${TIME_INPUT//d/ days}"
    elif [[ "$TIME_INPUT" =~ ^[0-9]+s$ ]]; then
        CLEAN_TIME="${TIME_INPUT//s/ seconds}"
    fi

    # 3. Validate using 'date' with the cleaned string
    if ! date -d "$CLEAN_TIME ago" >/dev/null 2>&1; then
        echo "    [!] Invalid time format '$TIME_INPUT'. Defaulting to 10 minutes."
        CLEAN_TIME="10 minutes"
    fi

    # 4. Calculate Start Epoch and Duration (for RPS accuracy)
    START_TIME=$(date -d "$CLEAN_TIME ago" +%s)
    CURRENT_TIME=$(date +%s)
    DURATION=$((CURRENT_TIME - START_TIME))
    
    if [ "$DURATION" -le 0 ]; then DURATION=600; fi

    echo "    Analyzing last $CLEAN_TIME (~$DURATION seconds)..."
    
    for LOG_FILE in $LOG_FILES; do
        echo "    ---------------------------------------------"
        echo "    Analyzing: $(basename "$LOG_FILE")"
        
        tail -n 200000 "$LOG_FILE" | awk -v limit="$START_TIME" -v duration="$DURATION" '
        BEGIN {
            m["Jan"]=1; m["Feb"]=2; m["Mar"]=3; m["Apr"]=4; m["May"]=5; m["Jun"]=6;
            m["Jul"]=7; m["Aug"]=8; m["Sep"]=9; m["Oct"]=10; m["Nov"]=11; m["Dec"]=12;
            count_total=0; count_php=0; count_other=0;
        }
        {
            t_str = substr($4, 2);
            split(t_str, a, /[\/:]/);
            timestamp = mktime(a[3] " " m[a[2]] " " a[1] " " a[4] " " a[5] " " a[6]);
            
            if (timestamp >= limit) {
                count_total++;
                if ($7 ~ /index\.php/) {
                    count_php++;
                } else {
                    count_other++;
                }
            }
        }
        END {
            if (count_total == 0) {
                print "    [i] No requests found in this timeframe.";
            } else {
                printf "    Total Requests:        %d\n", count_total;
                printf "    With index.php:        %d\n", count_php;
                printf "    Other Requests:        %d\n", count_other;
                printf "    Overall RPS:           %.2f req/sec\n", count_total / duration;
                printf "    Index.php RPS:         %.2f req/sec\n", count_php / duration;
            }
        }
        '
    done
else
    echo "    [!] Could not locate any access logs."
fi

# ------------------------------------------------------------------------------
# 9. REAL-TIME STATUS PAGE CHECK
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[9] Real-Time Status Page${NC}"

if [ -z "$STATUS_PATH" ]; then
    echo "    [!] Status page is NOT enabled in config (pm.status_path)."
else
    echo "    [OK] Status Path is enabled: $STATUS_PATH"
    
    if command -v cgi-fcgi &> /dev/null; then
        echo "    Fetching status via cgi-fcgi..."
        echo "    ---------------------------------------------"
        
        if [[ "$LISTEN" == /* ]]; then
            CONN_FLAG="-bind -connect $LISTEN"
        else
            CONN_FLAG="-bind -connect $LISTEN"
        fi

        SCRIPT_NAME=$STATUS_PATH \
        SCRIPT_FILENAME=$STATUS_PATH \
        REQUEST_METHOD=GET \
        cgi-fcgi $CONN_FLAG 2>/dev/null | grep -E "pool:|process manager|start time|accepted conn|listen queue|active processes|slow requests"
        
        echo "    ---------------------------------------------"
    else
        echo "    [i] 'cgi-fcgi' tool not found. Install it to query status from CLI:"
        echo "        yum install fcgi"
        echo ""
        URL_PATH="/$(echo "$STATUS_PATH" | sed 's|^/||')"
        if [[ "$LISTEN" == /* ]]; then PASS_VAL="unix:${LISTEN}"; else PASS_VAL="${LISTEN}"; fi
        echo "    Alternatively, view via web browser (if web server configured):"
        echo "    http://localhost${URL_PATH}"
    fi
fi

# ------------------------------------------------------------------------------
# 10. LOG INSPECTOR (NEW)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[10] Log Inspector${NC}"

# PHP Slow Log
if [ -n "$PHP_SLOWLOG" ] && [ -f "$PHP_SLOWLOG" ]; then
    echo "    [PHP-FPM] Slow Log ($PHP_SLOWLOG) - Last 5 entries:"
    echo "    ---------------------------------------------"
    tail -n 10 "$PHP_SLOWLOG"
    echo "    ---------------------------------------------"
elif [ -n "$PHP_SLOWLOG" ]; then
     echo "    [PHP-FPM] Slow log configured ($PHP_SLOWLOG) but file not found/readable."
else
     echo "    [PHP-FPM] Slow log not detected in config."
fi

# MySQL Slow Log
if [ -n "$SQ_FILE" ] && [ -f "$SQ_FILE" ]; then
    echo "    [MySQL] Slow Log ($SQ_FILE) - Last 10 lines:"
    echo "    ---------------------------------------------"
    # Just show raw tail. If user wants summary, they can run mysqldumpslow manually
    tail -n 10 "$SQ_FILE"
    echo "    ---------------------------------------------"
else
    echo "    [MySQL] Slow log not detected/enabled or file unreadable."
fi

# ------------------------------------------------------------------------------
# 11. STRACE (OPTIONAL)
# ------------------------------------------------------------------------------
# Only ask if interactive
if [ -t 0 ]; then
    echo -e "\n${YELLOW}[11] Deep Trace (strace)${NC}"
    TOP_PID=$(ps -ylC php-fpm --sort:-pcpu | head -n 2 | tail -n 1 | awk '{print $3}')
    
    if [ ! -z "$TOP_PID" ]; then
        read -p "    Trace top process PID $TOP_PID for 5 seconds? (y/n) " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "    Tracing... (Wait 5s)"
            if command -v strace &> /dev/null; then
                # Run trace
                timeout 5s strace -s 200 -f -p "$TOP_PID" 2>&1 | tee fpm_trace.log | head -n 15
                echo -e "\n    ... trace output truncated."
                echo "    Full log saved to: fpm_trace.log"
                
                # Check for idle indication
                if grep -q "accept(" fpm_trace.log; then
                    echo -e "    ${YELLOW}[INFO] 'accept(...)' seen? The process was idle waiting for requests.${NC}"
                fi
            else
                 echo "    [!] strace not installed. Install with: yum install strace"
            fi
        fi
    fi
fi

echo ""
