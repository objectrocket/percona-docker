#!/bin/bash
# MongoDB Health Check Script for Kubernetes

set -euo pipefail

# Configuration
MONGODB_HOST="${MONGODB_HOST:-localhost}"
MONGODB_PORT="${MONGODB_PORT:-27017}"
MONGODB_DATABASE="${MONGODB_DATABASE:-admin}"
TIMEOUT="${HEALTH_CHECK_TIMEOUT:-10}"
MAX_RETRIES="${HEALTH_CHECK_RETRIES:-3}"

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] HEALTHCHECK: $*" >&2
}

# Function to check if MongoDB is accepting connections
check_connection() {
    local retry=0
    while [ $retry -lt $MAX_RETRIES ]; do
        if timeout $TIMEOUT mongosh --host "$MONGODB_HOST" --port "$MONGODB_PORT" --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            return 0
        fi
        retry=$((retry + 1))
        log "Connection attempt $retry failed, retrying..."
        sleep 1
    done
    return 1
}

# Function to check MongoDB server status
check_server_status() {
    local status_output
    status_output=$(timeout $TIMEOUT mongosh --host "$MONGODB_HOST" --port "$MONGODB_PORT" --quiet --eval "
        try {
            var status = db.adminCommand('serverStatus');
            if (status.ok === 1) {
                print('OK');
            } else {
                print('ERROR: Server status not OK');
            }
        } catch (e) {
            print('ERROR: ' + e.message);
        }
    " 2>/dev/null)
    
    if [[ "$status_output" == "OK" ]]; then
        return 0
    else
        log "Server status check failed: $status_output"
        return 1
    fi
}

# Function to check if MongoDB is ready for read/write operations
check_readiness() {
    local readiness_output
    readiness_output=$(timeout $TIMEOUT mongosh --host "$MONGODB_HOST" --port "$MONGODB_PORT" --quiet --eval "
        try {
            // Check if we can perform basic operations
            db.healthcheck.insertOne({timestamp: new Date(), check: 'readiness'});
            db.healthcheck.findOne({check: 'readiness'});
            db.healthcheck.deleteMany({check: 'readiness'});
            print('READY');
        } catch (e) {
            print('NOT_READY: ' + e.message);
        }
    " 2>/dev/null)
    
    if [[ "$readiness_output" == "READY" ]]; then
        return 0
    else
        log "Readiness check failed: $readiness_output"
        return 1
    fi
}

# Function to check replica set status (if applicable)
check_replica_set() {
    local rs_output
    rs_output=$(timeout $TIMEOUT mongosh --host "$MONGODB_HOST" --port "$MONGODB_PORT" --quiet --eval "
        try {
            var status = rs.status();
            if (status.ok === 1) {
                var myState = status.members.find(m => m.self === true);
                if (myState && (myState.state === 1 || myState.state === 2)) {
                    print('RS_OK');
                } else {
                    print('RS_NOT_READY: State ' + (myState ? myState.state : 'unknown'));
                }
            } else {
                print('RS_ERROR: ' + status.errmsg);
            }
        } catch (e) {
            // Not a replica set or not initialized yet
            print('RS_NOT_CONFIGURED');
        }
    " 2>/dev/null)
    
    case "$rs_output" in
        "RS_OK")
            log "Replica set status: OK"
            return 0
            ;;
        "RS_NOT_CONFIGURED")
            log "Replica set not configured (standalone mode)"
            return 0
            ;;
        *)
            log "Replica set check failed: $rs_output"
            return 1
            ;;
    esac
}

# Function to check disk space
check_disk_space() {
    local data_dir="${MONGODB_DATA_DIR:-/data/db}"
    local log_dir="${MONGODB_LOG_DIR:-/var/log/mongodb}"
    local min_free_percent="${MIN_FREE_DISK_PERCENT:-10}"
    
    for dir in "$data_dir" "$log_dir"; do
        if [[ -d "$dir" ]]; then
            local usage
            usage=$(df "$dir" | awk 'NR==2 {print $5}' | sed 's/%//')
            local free_percent=$((100 - usage))
            
            if [[ $free_percent -lt $min_free_percent ]]; then
                log "Disk space warning: $dir has only $free_percent% free (minimum: $min_free_percent%)"
                return 1
            fi
        fi
    done
    return 0
}

# Function to check process health
check_process_health() {
    # Check if mongod process is running
    if ! pgrep -f mongod >/dev/null 2>&1; then
        log "MongoDB process not found"
        return 1
    fi
    
    # Check if process is responsive (not in uninterruptible sleep)
    local mongod_pid
    mongod_pid=$(pgrep -f mongod | head -1)
    if [[ -n "$mongod_pid" ]]; then
        local process_state
        process_state=$(ps -o state= -p "$mongod_pid" 2>/dev/null | tr -d ' ')
        if [[ "$process_state" == "D" ]]; then
            log "MongoDB process is in uninterruptible sleep state"
            return 1
        fi
    fi
    
    return 0
}

# Main health check function
main() {
    local exit_code=0
    local check_type="${1:-full}"
    
    log "Starting health check (type: $check_type)"
    
    # Always check process health first
    if ! check_process_health; then
        log "Process health check failed"
        exit_code=1
    fi
    
    # Check MongoDB connection
    if ! check_connection; then
        log "Connection check failed"
        exit_code=1
    fi
    
    # For full health checks, perform additional tests
    if [[ "$check_type" == "full" ]]; then
        # Check server status
        if ! check_server_status; then
            log "Server status check failed"
            exit_code=1
        fi
        
        # Check readiness for operations
        if ! check_readiness; then
            log "Readiness check failed"
            exit_code=1
        fi
        
        # Check replica set status if applicable
        if ! check_replica_set; then
            log "Replica set check failed"
            exit_code=1
        fi
        
        # Check disk space
        if ! check_disk_space; then
            log "Disk space check failed"
            exit_code=1
        fi
    fi
    
    if [[ $exit_code -eq 0 ]]; then
        log "Health check passed"
    else
        log "Health check failed"
    fi
    
    exit $exit_code
}

# Handle different invocation modes
case "${1:-full}" in
    "liveness"|"live")
        # Liveness probe - basic connection check
        main "basic"
        ;;
    "readiness"|"ready")
        # Readiness probe - full functionality check
        main "full"
        ;;
    "startup")
        # Startup probe - basic connection with retries
        MAX_RETRIES=10
        TIMEOUT=30
        main "basic"
        ;;
    *)
        # Default full health check
        main "full"
        ;;
esac
