#!/bin/bash
# Enhanced MongoDB Entrypoint Script for Kubernetes
# Optimized for Kubernetes deployments with improved signal handling, configuration management, and operator integration

set -Eeuo pipefail

# Configuration variables
MONGODB_DATA_DIR="${MONGODB_DATA_DIR:-/data/db}"
MONGODB_LOG_DIR="${MONGODB_LOG_DIR:-/var/log/mongodb}"
MONGODB_CONFIG_DIR="${MONGODB_CONFIG_DIR:-/etc/mongodb}"
MONGODB_USER="${MONGODB_USER:-mongodb}"
MONGODB_UID="${MONGODB_UID:-1001}"
MONGODB_GID="${MONGODB_GID:-0}"

# Kubernetes-specific variables
K8S_NAMESPACE="${K8S_NAMESPACE:-}"
K8S_POD_NAME="${K8S_POD_NAME:-}"
K8S_SERVICE_NAME="${K8S_SERVICE_NAME:-}"
REPLICA_SET_NAME="${REPLICA_SET_NAME:-rs0}"

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ENTRYPOINT: $*" >&2
}

# Error handling
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Signal handling for graceful shutdown
shutdown_handler() {
    log "Received shutdown signal, initiating graceful shutdown..."
    
    # If MongoDB is running, try to shut it down gracefully
    if pgrep -f mongod >/dev/null 2>&1; then
        log "Shutting down MongoDB gracefully..."
        
        # Try to use MongoDB's shutdown command first
        if mongosh --quiet --eval "db.adminCommand('shutdown')" >/dev/null 2>&1; then
            log "MongoDB shutdown command sent successfully"
        else
            log "MongoDB shutdown command failed, sending SIGTERM to process"
            pkill -TERM mongod || true
        fi
        
        # Wait for process to exit gracefully
        local timeout=30
        while pgrep -f mongod >/dev/null 2>&1 && [ $timeout -gt 0 ]; do
            sleep 1
            timeout=$((timeout - 1))
        done
        
        if pgrep -f mongod >/dev/null 2>&1; then
            log "MongoDB did not shut down gracefully, sending SIGKILL"
            pkill -KILL mongod || true
        else
            log "MongoDB shut down gracefully"
        fi
    fi
    
    exit 0
}

# Set up signal handlers
trap shutdown_handler SIGTERM SIGINT SIGQUIT

# Function to setup directories and permissions
setup_directories() {
    log "Setting up directories and permissions..."
    
    # Create necessary directories
    for dir in "$MONGODB_DATA_DIR" "$MONGODB_LOG_DIR" "$MONGODB_CONFIG_DIR" "/tmp/mongodb"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log "Created directory: $dir"
        fi
    done
    
    # Set ownership and permissions for Kubernetes/OpenShift compatibility
    chown -R "$MONGODB_UID:$MONGODB_GID" "$MONGODB_DATA_DIR" "$MONGODB_LOG_DIR" "$MONGODB_CONFIG_DIR" "/tmp/mongodb" 2>/dev/null || true
    chmod -R g+rwx "$MONGODB_DATA_DIR" "$MONGODB_LOG_DIR" "$MONGODB_CONFIG_DIR" "/tmp/mongodb" 2>/dev/null || true
    chmod -R o-rwx "$MONGODB_DATA_DIR" "$MONGODB_LOG_DIR" "$MONGODB_CONFIG_DIR" 2>/dev/null || true
}

# Function to handle file-based environment variables (Kubernetes secrets)
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    
    if [[ -n "${!var:-}" ]] && [[ -n "${!fileVar:-}" ]]; then
        error_exit "Both $var and $fileVar are set (but are exclusive)"
    fi
    
    local val="$def"
    if [[ -n "${!var:-}" ]]; then
        val="${!var}"
    elif [[ -n "${!fileVar:-}" ]]; then
        if [[ -f "${!fileVar}" ]]; then
            val="$(< "${!fileVar}")"
        else
            error_exit "File ${!fileVar} does not exist"
        fi
    fi
    
    export "$var"="$val"
    unset "$fileVar" 2>/dev/null || true
}

# Function to generate MongoDB configuration
generate_config() {
    local config_file="$MONGODB_CONFIG_DIR/mongod.conf"
    
    log "Generating MongoDB configuration..."
    
    # Start with template if it exists
    if [[ -f "$MONGODB_CONFIG_DIR/mongod.conf.template" ]]; then
        cp "$MONGODB_CONFIG_DIR/mongod.conf.template" "$config_file"
    else
        # Create basic configuration
        cat > "$config_file" << EOF
# MongoDB configuration for Kubernetes
storage:
  dbPath: $MONGODB_DATA_DIR
  journal:
    enabled: true

systemLog:
  destination: file
  logAppend: true
  path: $MONGODB_LOG_DIR/mongod.log
  logRotate: reopen

net:
  port: 27017
  bindIpAll: true

processManagement:
  timeZoneInfo: /usr/share/zoneinfo

security:
  authorization: disabled
EOF
    fi
    
    # Add replica set configuration if specified
    if [[ -n "$REPLICA_SET_NAME" ]]; then
        if ! grep -q "replication:" "$config_file"; then
            cat >> "$config_file" << EOF

replication:
  replSetName: $REPLICA_SET_NAME
EOF
        fi
    fi
    
    # Set proper permissions
    chown "$MONGODB_UID:$MONGODB_GID" "$config_file"
    chmod 640 "$config_file"
    
    log "MongoDB configuration generated at $config_file"
}

# Function to wait for network readiness
wait_for_network() {
    log "Waiting for network readiness..."
    
    local timeout=30
    while [ $timeout -gt 0 ]; do
        if ss -tuln | grep -q ":27017 "; then
            log "Port 27017 is already in use, waiting..."
            sleep 1
            timeout=$((timeout - 1))
        else
            break
        fi
    done
    
    if [ $timeout -eq 0 ]; then
        log "Warning: Port 27017 may still be in use"
    fi
}

# Function to initialize MongoDB if needed
initialize_mongodb() {
    log "Checking if MongoDB initialization is needed..."
    
    # Check if this is a fresh installation
    if [[ ! -f "$MONGODB_DATA_DIR/WiredTiger" ]] && [[ ! -f "$MONGODB_DATA_DIR/mongod.lock" ]]; then
        log "Fresh MongoDB installation detected"
        
        # Handle initialization scripts
        file_env 'MONGO_INITDB_ROOT_USERNAME'
        file_env 'MONGO_INITDB_ROOT_PASSWORD'
        file_env 'MONGO_INITDB_DATABASE'
        
        if [[ -n "${MONGO_INITDB_ROOT_USERNAME:-}" ]] && [[ -n "${MONGO_INITDB_ROOT_PASSWORD:-}" ]]; then
            log "Root user credentials provided, will initialize with authentication"
            export MONGO_INITDB_ROOT_USERNAME
            export MONGO_INITDB_ROOT_PASSWORD
            export MONGO_INITDB_DATABASE="${MONGO_INITDB_DATABASE:-admin}"
        fi
    else
        log "Existing MongoDB data found, skipping initialization"
    fi
}

# Function to setup MongoDB arguments with Kubernetes optimizations
setup_mongodb_args() {
    local -a mongod_args=("$@")
    
    # If no arguments provided, use default
    if [[ ${#mongod_args[@]} -eq 0 ]]; then
        mongod_args=("mongod")
    fi
    
    # If first argument starts with -, prepend mongod
    if [[ "${mongod_args[0]:0:1}" = '-' ]]; then
        mongod_args=("mongod" "${mongod_args[@]}")
    fi
    
    # Add Kubernetes-specific optimizations
    local -a k8s_args=()
    
    # Use configuration file if it exists
    if [[ -f "$MONGODB_CONFIG_DIR/mongod.conf" ]]; then
        k8s_args+=("--config" "$MONGODB_CONFIG_DIR/mongod.conf")
    fi
    
    # Kubernetes-specific settings
    k8s_args+=(
        "--bind_ip_all"
        "--logpath" "$MONGODB_LOG_DIR/mongod.log"
        "--logappend"
    )
    
    # Add NUMA optimization if available
    if command -v numactl >/dev/null 2>&1 && numactl --hardware >/dev/null 2>&1; then
        mongod_args=("numactl" "--interleave=all" "${mongod_args[@]}")
    fi
    
    # Combine arguments
    mongod_args+=("${k8s_args[@]}")
    
    echo "${mongod_args[@]}"
}

# Function to start MongoDB with proper user switching
start_mongodb() {
    local -a mongod_cmd=($@)
    
    log "Starting MongoDB with command: ${mongod_cmd[*]}"
    
    # Ensure we're running as the correct user
    if [[ "$(id -u)" = '0' ]]; then
        # Running as root, switch to mongodb user
        log "Running as root, switching to user $MONGODB_USER (UID: $MONGODB_UID)"
        
        # Ensure ownership of critical files
        chown "$MONGODB_UID:$MONGODB_GID" "$MONGODB_DATA_DIR" "$MONGODB_LOG_DIR" 2>/dev/null || true
        
        # Use gosu to switch user and exec
        exec gosu "$MONGODB_UID:$MONGODB_GID" "${mongod_cmd[@]}"
    else
        # Already running as non-root user
        log "Running as user $(id -un) (UID: $(id -u))"
        exec "${mongod_cmd[@]}"
    fi
}

# Function to check if command is MongoDB-related
is_mongodb_command() {
    local cmd="$1"
    
    # List of MongoDB-related commands
    case "$cmd" in
        mongod|mongos|mongo|mongosh)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Main execution function
main() {
    # Check if we should run MongoDB initialization or just exec the command
    local first_arg="${1:-mongod}"
    
    # If the first argument is not a MongoDB command, just exec it directly
    # This allows for command overrides like: docker run image echo "hello"
    if ! is_mongodb_command "$first_arg"; then
        log "Non-MongoDB command detected: $first_arg"
        log "Executing command directly without MongoDB initialization"
        
        # If running as root, switch to mongodb user for consistency
        if [[ "$(id -u)" = '0' ]]; then
            exec gosu "$MONGODB_UID:$MONGODB_GID" "$@"
        else
            exec "$@"
        fi
    fi
    
    # MongoDB command detected, proceed with full initialization
    log "Starting MongoDB entrypoint for Kubernetes..."
    log "Pod: ${K8S_POD_NAME:-unknown}, Namespace: ${K8S_NAMESPACE:-unknown}"
    
    # Setup directories and permissions
    setup_directories
    
    # Wait for network readiness
    wait_for_network
    
    # Generate configuration
    generate_config
    
    # Initialize MongoDB if needed
    initialize_mongodb
    
    # Setup MongoDB arguments
    local -a final_args
    IFS=' ' read -ra final_args <<< "$(setup_mongodb_args "$@")"
    
    # Start MongoDB
    start_mongodb "${final_args[@]}"
}

# Execute main function with all arguments
main "$@"