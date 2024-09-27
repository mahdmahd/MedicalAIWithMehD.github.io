#!/bin/bash

# URLs to download configurations
config_urls=(
    "https://github.com/mahsanet/MahsaFreeConfig/raw/main/mci/sub_3.txt"
    "https://github.com/mahsanet/MahsaFreeConfig/raw/main/mci/sub_1.txt"
    "https://github.com/mahsanet/MahsaFreeConfig/raw/main/mci/sub_2.txt"
    "https://github.com/mahsanet/MahsaFreeConfig/raw/main/mci/sub_4.txt"
    "https://github.com/mahsanet/MahsaFreeConfig/raw/main/mtn/sub_1.txt"
    "https://github.com/mahsanet/MahsaFreeConfig/raw/main/mtn/sub_2.txt"
    "https://github.com/mahsanet/MahsaFreeConfig/raw/main/mtn/sub_3.txt"
    "https://github.com/mahsanet/MahsaFreeConfig/raw/main/mtn/sub_4.txt"
)

# Function to download and return configs
download_configs() {
    echo "[Step 1] Downloading base64-encoded configurations from URLs..."
    configs=()
    for url in "${config_urls[@]}"; do
        echo "Downloading from $url..."
        content=$(curl -s -L "$url")
        if [ $? -eq 0 ] && [ -n "$content" ]; then
            configs+=("$content")
            echo "Downloaded successfully from $url"
        else
            echo "Failed to download from $url"
        fi
    done
    echo "[Step 1 Complete] Downloaded ${#configs[@]} configurations."
}

# Function to encode a file to base64
encode_file_base64() {
    input_file="$1"
    output_file="$2"
    if [ ! -f "$input_file" ]; then
        echo "Error: $input_file not found."
        return 1
    fi
    base64 "$input_file" > "$output_file"
    if [ $? -eq 0 ]; then
        echo "File $input_file encoded to base64 and saved as $output_file."
    else
        echo "Error encoding $input_file to base64."
    fi
}

# Function to compute hash of the downloaded configs for change detection
compute_config_hash() {
    echo -n "$1" | md5sum | awk '{print $1}'
}

# Function to check for updates in configuration
check_for_updates() {
    initial_hash="$1"
    current_configs=$(cat config.txt)
    current_hash=$(compute_config_hash "$current_configs")
    if [ "$initial_hash" != "$current_hash" ]; then
        echo "Configurations have changed. Restarting process."
        return 1
    else
        echo "No changes in configuration."
        return 0
    fi
}

# Function to parse VLESS URLs
parse_vless() {
    local url="$1"
    echo "Parsing VLESS URL: $url"
    local id=$(echo "$url" | awk -F'[:@]' '{print $2}')
    local address=$(echo "$url" | awk -F'[@:]' '{print $3}')
    local port=$(echo "$url" | awk -F':' '{print $4}')
    echo "{ \"protocol\": \"vless\", \"id\": \"$id\", \"address\": \"$address\", \"port\": $port }"
}

# Function to parse VMess URLs
parse_vmess() {
    local url="$1"
    echo "Parsing VMess URL: $url"
    local vmess_data=$(echo "$url" | sed 's/vmess:\/\///')
    local decoded=$(echo "$vmess_data" | base64 -d 2>/dev/null)
    echo "$decoded"
}

# Function to parse Trojan URLs
parse_trojan() {
    local url="$1"
    echo "Parsing Trojan URL: $url"
    local password=$(echo "$url" | awk -F'[:@]' '{print $2}')
    local address=$(echo "$url" | awk -F'[@:]' '{print $3}')
    local port=$(echo "$url" | awk -F':' '{print $4}')
    echo "{ \"protocol\": \"trojan\", \"password\": \"$password\", \"address\": \"$address\", \"port\": $port }"
}

# Function to generate outbound rules for Xray
generate_outbound() {
    local protocol="$1"
    local config="$2"
    local tag="$3"
    echo "Generating outbound rule for $protocol with tag: $tag"
    case $protocol in
        "vless"|"trojan"|"vmess")
            echo "$config" | jq --arg tag "$tag" --argjson conf "$config" '
            {
                tag: $tag,
                protocol: .protocol,
                settings: {
                    vnext: [{
                        address: .address,
                        port: .port,
                        users: [{
                            id: .id
                        }]
                    }]
                }
            }'
            ;;
        *)
            echo "Unsupported protocol: $protocol"
            ;;
    esac
}

# Function to merge configurations and save them into config.txt
merge_and_save_configs() {
    echo "[Step 2] Merging and saving decoded configurations into config.txt..."
    > config.txt
    for config in "${configs[@]}"; do
        decoded=$(echo "$config" | base64 -d 2>/dev/null)
        if [ -n "$decoded" ]; then
            echo "$decoded" >> config.txt
        fi
    done
    echo "[Step 2 Complete] Decoded configurations saved to config.txt."
}

# Function to generate configSpeedtest.json
generate_config_speedtest() {
    echo "[Step 3] Generating configSpeedtest.json..."
    inbounds=""
    outbounds=""
    routing_rules=""
    proxy_index=10100

    while read -r line; do
        protocol=""
        config_json=""

        if echo "$line" | grep -q "^vless://"; then
            protocol="vless"
            config_json=$(parse_vless "$line")
        elif echo "$line" | grep -q "^vmess://"; then
            protocol="vmess"
            config_json=$(parse_vmess "$line")
        elif echo "$line" | grep -q "^trojan://"; then
            protocol="trojan"
            config_json=$(parse_trojan "$line")
        else
            echo "Unsupported protocol in line: $line"
            continue
        fi

        if [ -n "$config_json" ]; then
            outbound=$(generate_outbound "$protocol" "$config_json" "proxy${proxy_index}")
            outbounds="$outbounds,$outbound"
            inbounds="$inbounds,{\"port\":$proxy_index,\"listen\":\"127.0.0.1\",\"protocol\":\"socks\"}"
            routing_rules="$routing_rules,{\"inboundTag\":[\"http${proxy_index}\"],\"outboundTag\":\"proxy${proxy_index}\"}"
            proxy_index=$((proxy_index + 1))
        fi
    done < config.txt

    # Remove leading commas
    outbounds=$(echo "$outbounds" | sed 's/^,//')
    inbounds=$(echo "$inbounds" | sed 's/^,//')
    routing_rules=$(echo "$routing_rules" | sed 's/^,//')

    # Create the final configSpeedtest.json
    cat <<EOF > configSpeedtest.json
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        $inbounds
    ],
    "outbounds": [
        { "protocol": "freedom", "tag": "direct", "settings": {} },
        { "protocol": "blackhole", "tag": "block", "settings": { "response": { "type": "http" } } }
        $outbounds
    ],
    "routing": {
        "rules": [
            $routing_rules
        ]
    }
}
EOF

    echo "[Step 3 Complete] configSpeedtest.json generated."
}

# Function to run Xray
run_xray() {
    echo "[Step 4] Running Xray..."
    ./xray -config configSpeedtest.json &
    xray_pid=$!
    echo "Xray started with PID $xray_pid"
}

# Function to test proxies
test_proxies() {
    proxy_list=("$@")
    url="https://vimeo.com/946171968"
    response_times=()

    for port in "${proxy_list[@]}"; do
        echo "Testing proxy on port $port..."
        response_time=$(curl --socks5 127.0.0.1:$port -o /dev/null -s -w "%{time_total}" "$url" --max-time 1)
        if [ $? -eq 0 ]; then
            response_times+=("$port:$response_time")
            echo "Port $port: $response_time seconds"
        else
            echo "Port $port failed."
        fi
    done
    echo "${response_times[@]}"
}

# Main execution
main() {
    # Step 1: Download configurations
    download_configs

    # Step 2: Merge and save configurations
    merge_and_save_configs

    # Step 3: Generate configSpeedtest.json
    generate_config_speedtest

    # Step 4: Run Xray
    run_xray

    # Wait for Xray to start
    sleep 5

    # Add further steps like proxy testing or monitoring if needed
}

# Main loop to check for updates every 5 minutes
run_in_loop() {
    initial_config=$(cat config.txt)
    initial_hash=$(compute_config_hash "$initial_config")

    while true; do
        # Test proxies and do other actions...
        check_for_updates "$initial_hash"
        if [ $? -eq 1 ]; then
            # Re-download configs and regenerate if there are changes
            main
        fi
        sleep 300  # Wait for 5 minutes before the next check
    done
}

# Start the script
main
run_in_loop
