#!/bin/bash
# Source Update Cache Manager
# Manages files in /var/lib/adu/sdc/ directory

set -e

CACHE_BASE_DIR="/var/lib/adu/sdc"
ADU_USER="adu"
ADU_GROUP="adu"

usage() {
    cat << 'EOF'
Source Update Cache Manager

Usage: $0 <command> [options]

Commands:
  store <file> <provider> <version>  Store a file in cache
  lookup <provider> <version>        Look up a file in cache
  list [provider]                    List cached files
  info                               Show cache information

Examples:
  $0 store adu-update-image-v1-recompressed.swu "Contoso" "1.0.0"
  $0 lookup "Contoso" "1.0.0"
  $0 list

Cache Structure: ${CACHE_BASE_DIR}/<provider>/sha256-<hash>
EOF
}

calculate_hash() {
    sha256sum "$1" | awk '{print $1}'
}

url_encode() {
    echo -n "$1" | jq -sRr @uri 2>/dev/null || echo -n "$1" | sed 's/ /%20/g'
}

get_cache_path() {
    local provider="$1"
    local hash="$2"
    local provider_encoded=$(url_encode "$provider")
    echo "${CACHE_BASE_DIR}/${provider_encoded}/sha256-${hash}"
}

store_file() {
    local source_file="$1"
    local provider="$2"
    local version="$3"
    
    if [ ! -f "$source_file" ]; then
        echo "Error: File not found: $source_file"
        return 1
    fi
    
    echo "Storing file in cache..."
    echo "  File: $source_file"
    echo "  Provider: $provider"
    echo "  Version: $version"
    
    local hash=$(calculate_hash "$source_file")
    echo "  Hash: $hash"
    
    local cache_path=$(get_cache_path "$provider" "$hash")
    echo "  Cache path: $cache_path"
    
    sudo mkdir -p "$(dirname "$cache_path")"
    sudo cp "$source_file" "$cache_path"
    sudo chown ${ADU_USER}:${ADU_GROUP} "$cache_path"
    sudo chmod 644 "$cache_path"
    
    local meta_file="${cache_path}.meta"
    local file_size=$(stat -c%s "$source_file")
    local cached_at=$(date -Iseconds)
    
    echo "{" > /tmp/cache_meta.json
    echo "  \"provider\": \"$provider\"," >> /tmp/cache_meta.json
    echo "  \"version\": \"$version\"," >> /tmp/cache_meta.json
    echo "  \"hash\": \"$hash\"," >> /tmp/cache_meta.json
    echo "  \"algorithm\": \"sha256\"," >> /tmp/cache_meta.json
    echo "  \"cached_at\": \"$cached_at\"," >> /tmp/cache_meta.json
    echo "  \"file_size\": $file_size" >> /tmp/cache_meta.json
    echo "}" >> /tmp/cache_meta.json
    
    sudo mv /tmp/cache_meta.json "$meta_file"
    sudo chown ${ADU_USER}:${ADU_GROUP} "$meta_file"
    
    echo "✓ File stored successfully"
}

lookup_file() {
    local provider="$1"
    local version="$2"
    local provider_dir="${CACHE_BASE_DIR}/$(url_encode "$provider")"
    
    if [ ! -d "$provider_dir" ]; then
        echo "✗ No cache for provider: $provider"
        return 1
    fi
    
    echo "Looking up: Provider=$provider, Version=$version"
    
    local found=0
    for meta_file in "$provider_dir"/*.meta; do
        if [ -f "$meta_file" ]; then
            local meta_version=$(jq -r .version "$meta_file" 2>/dev/null || grep -oP '"version":\s*"\K[^"]+' "$meta_file")
            if [ "$meta_version" = "$version" ]; then
                echo "✓ Found: ${meta_file%.meta}"
                if command -v jq >/dev/null 2>&1; then
                    jq . "$meta_file"
                else
                    cat "$meta_file"
                fi
                found=1
            fi
        fi
    done
    
    if [ $found -eq 0 ]; then
        echo "✗ Not found"
        return 1
    fi
}

list_cache() {
    local provider="$1"
    echo "Cached files in: ${CACHE_BASE_DIR}"
    
    if [ ! -d "$CACHE_BASE_DIR" ]; then
        echo "Cache directory does not exist"
        return 0
    fi
    
    if [ -n "$provider" ]; then
        local provider_encoded=$(url_encode "$provider")
        dirs=("${CACHE_BASE_DIR}/${provider_encoded}")
    else
        dirs=("$CACHE_BASE_DIR"/*)
    fi
    
    for dir in "${dirs[@]}"; do
        if [ -d "$dir" ]; then
            echo ""
            echo "Provider: $(basename "$dir")"
            for meta_file in "$dir"/*.meta; do
                if [ -f "$meta_file" ]; then
                    local version=$(jq -r .version "$meta_file" 2>/dev/null || grep -oP '"version":\s*"\K[^"]+' "$meta_file" || echo "unknown")
                    local size=$(jq -r .file_size "$meta_file" 2>/dev/null || grep -oP '"file_size":\s*\K[0-9]+' "$meta_file" || echo "unknown")
                    echo "  Version: $version, Size: $size bytes"
                fi
            done
        fi
    done
}

show_info() {
    echo "Cache Directory: $CACHE_BASE_DIR"
    if [ -d "$CACHE_BASE_DIR" ]; then
        echo "Total Size: $(du -sh "$CACHE_BASE_DIR" 2>/dev/null | cut -f1)"
        echo "File Count: $(find "$CACHE_BASE_DIR" -type f ! -name "*.meta" 2>/dev/null | wc -l)"
    else
        echo "Status: Not created yet"
    fi
}

# Main command dispatcher
case "${1:-}" in
    store)
        if [ $# -eq 4 ]; then
            store_file "$2" "$3" "$4"
        else
            echo "Usage: $0 store <file> <provider> <version>"
            exit 1
        fi
        ;;
    lookup)
        if [ $# -eq 3 ]; then
            lookup_file "$2" "$3"
        else
            echo "Usage: $0 lookup <provider> <version>"
            exit 1
        fi
        ;;
    list)
        list_cache "${2:-}"
        ;;
    info)
        show_info
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac
