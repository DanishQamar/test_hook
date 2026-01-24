#!/bin/bash

# ==============================================================================
# ADVANCED PHP-FPM ANALYZER (CentOS 7)
# ==============================================================================
# 1. Checks installed RPM version and OS.
# 2. Identifies top CPU consumers.
# 3. Calculates average Memory per PHP process.
# 4. Estimates Max Child capacity based on available RAM.
# 5. Checks PHP-FPM Pool Config (pm.max_children, slowlog).
# 6. Attempts to fetch the Real-Time Status Page (if enabled).
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

if [ -f "$CONF_FILE" ]; then
    echo "    Config File: $CONF_FILE"
    
    # Extract settings
    PM_MODE=$(grep "^pm =" "$CONF_FILE" | cut -d = -f 2 | xargs)
    MAX_CHILDREN=$(grep "^pm.max_children" "$CONF_FILE" | cut -d = -f 2 | xargs)
    START_SERVERS=$(grep "^pm.start_servers" "$CONF_FILE" | cut -d = -f 2 | xargs)
    STATUS_PATH=$(grep "^pm.status_path" "$CONF_FILE" | cut -d = -f 2 | xargs)
    LISTEN=$(grep "^listen =" "$CONF_FILE" | cut -d = -f 2 | xargs)

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
# 5. REAL-TIME STATUS PAGE CHECK
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[5] Real-Time Status Page${NC}"

if [ -z "$STATUS_PATH" ]; then
    echo "    [!] Status page is NOT enabled in config (pm.status_path)."
    echo "        Enable it in $CONF_FILE to see 'Listen Queue' and 'Active Processes' in real-time."
    echo "        Add/Uncomment: pm.status_path = /status"
else
    echo "    [OK] Status Path is enabled: $STATUS_PATH"
    
    # Try to fetch status using cgi-fcgi if available
    if command -v cgi-fcgi &> /dev/null; then
        echo "    Fetching status via cgi-fcgi..."
        echo "    ---------------------------------------------"
        
        # Determine address for cgi-fcgi
        if [[ "$LISTEN" == /* ]]; then
            # Unix Socket
            CONN_FLAG="-bind -connect $LISTEN"
        else
            # TCP Port (e.g., 127.0.0.1:9000)
            CONN_FLAG="-bind -connect $LISTEN"
        fi

        # Fetch Full Status
        SCRIPT_NAME=$STATUS_PATH \
        SCRIPT_FILENAME=$STATUS_PATH \
        REQUEST_METHOD=GET \
        cgi-fcgi $CONN_FLAG 2>/dev/null | grep -E "pool:|process manager|start time|accepted conn|listen queue|active processes|slow requests"
        
        echo "    ---------------------------------------------"
    else
        echo "    [i] 'cgi-fcgi' tool not found. Install it to query status from CLI:"
        echo "        yum install fcgi"
        echo ""

        # Ensure path starts with / for URL display
        URL_PATH="/$(echo "$STATUS_PATH" | sed 's|^/||')"
        
        # Prepare fastcgi_pass syntax (prepend unix: if it's a socket)
        if [[ "$LISTEN" == /* ]]; then
            PASS_VAL="unix:${LISTEN}"
        else
            PASS_VAL="${LISTEN}"
        fi

        echo "    Alternatively, view via web browser (if web server configured):"
        echo "    http://localhost${URL_PATH}"
        echo ""
        echo "    [?] To configure Nginx for this URL, add this to your server block:"
        echo "        location ~ ^${URL_PATH}$ {"
        echo "            access_log off;"
        echo "            include fastcgi_params;"
        echo "            fastcgi_pass ${PASS_VAL};"
        echo "        }"
    fi
fi

# ------------------------------------------------------------------------------
# 6. STRACE (OPTIONAL)
# ------------------------------------------------------------------------------
# Only ask if interactive
if [ -t 0 ]; then
    echo -e "\n${YELLOW}[6] Deep Trace (strace)${NC}"
    TOP_PID=$(ps -ylC php-fpm --sort:-pcpu | head -n 2 | tail -n 1 | awk '{print $3}')
    
    if [ ! -z "$TOP_PID" ]; then
        read -p "    Trace top process PID $TOP_PID for 5 seconds? (y/n) " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "    Tracing... (Wait 5s)"
            if command -v strace &> /dev/null; then
                timeout 5s strace -s 200 -f -p "$TOP_PID" 2>&1 | tee fpm_trace.log | head -n 15
                echo -e "\n    ... trace output truncated."
                echo "    Full log saved to: fpm_trace.log"
            else
                 echo "    [!] strace not installed. Install with: yum install strace"
            fi
        fi
    fi
fi

echo ""
