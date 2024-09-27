#!/bin/sh

# Set the URLs to download configurations
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

# Paths to your helper scripts
VMESS_SCRIPT="vmess2json.sh"
VLESS_SCRIPT="vless2json.sh"
TROJAN_SCRIPT="trojan2json.sh"

# Ensure the helper scripts are executable
chmod +x "$VMESS_SCRIPT" "$VLESS_SCRIPT" "$TROJAN_SCRIPT"

# Function to encode a file to Base64
encode_file_base64() {
    input_file_path="$1"
    output_file_path="$2"

    if [ ! -f "$input_file_path" ]; then
        echo "Error: Input file $input_file_path does not exist."
        return 1
    fi

    base64 -w 0 "$input_file_path" > "$output_file_path"
    if [ $? -eq 0 ]; then
        echo "File $input_file_path encoded to base64 and saved as $output_file_path."
    else
        echo "Error encoding file $input_file_path to base64."
    fi
}

# Function to download configurations
download_configs() {
    echo "[Step 1] Downloading base64-encoded configurations from URLs..."
    configs_base64=()  # Initialize an array
    for url in "${config_urls[@]}"; do
        echo "Downloading from $url..."
        content=$(curl -s "$url")
        if [ $? -eq 0 ] && [ -n "$content" ]; then
            configs_base64+=("$content")
            echo "Downloaded successfully from $url"
        else
            echo "Failed to download from $url"
        fi
    done
    echo "[Step 1 Complete] Downloaded configurations."
}

# Function to decode base64 strings
decode_configs() {
    echo "[Step 2] Decoding configurations..."
    > config.txt  # Clear the file
    for base64_content in "${configs_base64[@]}"; do
        base64_content=$(echo "$base64_content" | tr -d '\n\r')  # Remove newlines
        if [ -n "$base64_content" ]; then
            decoded_content=$(echo "$base64_content" | base64 -d 2>/dev/null)
            if [ $? -eq 0 ]; then
                echo "$decoded_content" >> config.txt
            else
                echo "Failed to decode base64 content."
            fi
        fi
    done
    echo "[Step 2 Complete] Decoded configurations saved to config.txt"
}

# Function to compute hash of configurations
compute_config_hash() {
    md5sum config.txt | awk '{print $1}' > config_hash.txt
}

# Function to parse URLs and generate Xray config using helper scripts
generate_xray_config() {
    echo "[Step 3] Generating configSpeedtest.json..."
    # Initialize variables
    proxy_index=10100
    inbounds=""
    outbounds=""
    routing_rules=""
    proxy_list=()
    declare -A proxy_url_mapping  # Associative array for port-to-URL mapping

    # Read config.txt line by line
    while read -r line; do
        line=$(echo "$line" | tr -d '\r')
        if [ -z "$line" ]; then
            continue
        fi

        protocol=""
        config_json=""

        if echo "$line" | grep -q "^vless://"; then
            protocol="vless"
            # Use vless2json.sh script
            config_json=$(bash "$VLESS_SCRIPT" --socks5-proxy "$proxy_index" --json "$line")
        elif echo "$line" | grep -q "^vmess://"; then
            protocol="vmess"
            # Use vmess2json.sh script
            config_json=$(bash "$VMESS_SCRIPT" --socks5-proxy "$proxy_index" --json "$line")
        elif echo "$line" | grep -q "^trojan://"; then
            protocol="trojan"
            # Use trojan2json.sh script
            config_json=$(bash "$TROJAN_SCRIPT" --socks5-proxy "$proxy_index" --json "$line")
        else
            echo "Unsupported protocol in line: $line"
            continue
        fi

        # Check if the script returned a valid JSON
        if [ -n "$config_json" ]; then
            # Append inbounds, outbounds, and routing rules
            inbound=$(echo "$config_json" | jq -c '.inbounds[]')
            outbound=$(echo "$config_json" | jq -c '.outbounds[]')
            routing_rule=$(echo "$config_json" | jq -c '.routing.rules[]')

            inbounds="$inbounds
            $inbound,"

            outbounds="$outbounds
            $outbound,"

            routing_rules="$routing_rules
            $routing_rule,"

            proxy_list+=("$proxy_index")
            proxy_url_mapping["$proxy_index"]="$line"
            proxy_index=$((proxy_index + 1))
        else
            echo "Failed to generate configuration for line: $line"
        fi
    done < config.txt

    # Remove trailing commas
    inbounds=$(echo "$inbounds" | sed '$s/,$//')
    outbounds=$(echo "$outbounds" | sed '$s/,$//')
    routing_rules=$(echo "$routing_rules" | sed '$s/,$//')

    # Create configSpeedtest.json
    cat <<EOF > configSpeedtest.json
{
    "log": {"loglevel": "warning"},
    "inbounds": [$inbounds
    ],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom", "settings": {}},
        {"tag": "block", "protocol": "blackhole", "settings": {"response": {"type": "http"}}}$outbounds
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [$routing_rules
        ]
    }
}
EOF

    echo "[Step 3 Complete] configSpeedtest.json generated successfully."
}

# Function to run Xray using ./xray_softfloat
run_xray() {
    echo "[Step 4] Starting Xray..."
    ./xray_softfloat -config configSpeedtest.json >/dev/null 2>&1 &
    xray_pid=$!
    sleep 5  # Wait for Xray to start
    echo "Xray started with PID $xray_pid"
}

# Function to test proxies
test_proxies() {
    timeout_value="$1"
    output_file="$2"
    echo "[Testing Proxies] Timeout: $timeout_value seconds"
    url="https://vimeo.com/946171968"
    > "$output_file"  # Clear the file
    for port in "${proxy_list[@]}"; do
        start_time=$(date +%s.%N)
        response=$(curl --socks5 127.0.0.1:"$port" -o /dev/null -s -w "%{time_total}" --max-time "$timeout_value" "$url")
        if [ $? -eq 0 ]; then
            end_time=$(date +%s.%N)
            total_time=$(echo "$end_time - $start_time" | bc)
            echo "Port $port response time: $response seconds"
            echo "$port:$response" >> "$output_file"
        else
            echo "Port $port failed."
        fi
    done

    # Sort ports by response time
    sorted_ports=$(sort -t: -k2 -n "$output_file" | cut -d: -f1)
    echo "$sorted_ports" > "best_ports.txt"
    echo "[Testing Complete] Results saved to $output_file"
}

# Function to perform second-round testing
test_proxies_second_round() {
    echo "[Step 6] Performing second-round proxy testing..."
    # First round with 1-second timeout
    test_proxies 1 "response_times_first_round.txt"
    # Read top ports from first round
    top_ports=($(head -n 10 best_ports.txt))  # Adjust number as needed

    # Update proxy_list to only include top ports
    proxy_list=("${top_ports[@]}")

    # Second round with 0.5-second timeout
    test_proxies 0.5 "response_times_second_round.txt"

    # Read sorted ports from second round
    sorted_ports=($(cat best_ports.txt))
    echo "[Second-Round Testing Complete]"
}

# Function to save and encode best proxies to USB storage
save_and_encode_best_proxies() {
    echo "[Step 7] Saving and encoding best proxies..."

    # Mount USB storage
    mkdir -p /mnt/usb
    mount /dev/sda1 /mnt/usb

    # Save best proxies to best.txt
    > best.txt
    for port in "${proxy_list[@]}"; do
        echo "${proxy_url_mapping[$port]}" >> best.txt
    done

    # Encode best.txt to base64 and save as best64.txt on USB storage
    encode_file_base64 best.txt /mnt/usb/best64.txt

    # Unmount USB storage
    umount /mnt/usb

    echo "Best proxies saved and encoded to /mnt/usb/best64.txt"
}

# Function to copy configs for top ports
copy_configs_for_top_ports() {
    echo "[Step 8] Copying configSpeedtest.json to configX.json for top ports..."
    top_ports=($(head -n 3 best_ports.txt))  # Limit to top 3 ports
    i=1
    for port in "${top_ports[@]}"; do
        config_filename="config${i}.json"
        echo "Copying configSpeedtest.json to $config_filename..."
        cp configSpeedtest.json "$config_filename"
        echo "Copied to $config_filename."
        i=$((i + 1))
    done
}

# Function to check for configuration updates
check_for_updates() {
    echo "Checking for configuration updates..."
    compute_config_hash
    new_hash=$(cat config_hash.txt)
    if [ "$new_hash" != "$initial_hash" ]; then
        echo "Configurations have changed."
        kill "$xray_pid"
        initial_hash="$new_hash"
        return 1  # Signal to restart the process
    else
        echo "No configuration changes detected."
        return 0
    fi
}

# Main function to test proxies every 5 minutes
test_proxies_every_5_minutes() {
    while true; do
        echo "Running proxy tests..."
        # First and second-round tests
        test_proxies_second_round

        # Save and encode best proxies
        save_and_encode_best_proxies

        # Copy configs for top ports
        copy_configs_for_top_ports

        # Check if it's time to re-download configurations
        current_minute=$(date '+%M')
        if [ "$current_minute" -ge 40 ]; then
            echo "Checking for configuration updates..."
            download_configs
            decode_configs
            compute_config_hash
            new_hash=$(cat config_hash.txt)
            if [ "$new_hash" != "$initial_hash" ]; then
                echo "Configurations have been updated. Restarting..."
                kill "$xray_pid"
                initial_hash="$new_hash"
                return 1  # Signal to restart the script
            fi
        fi

        # Sleep for 5 minutes before the next round
        sleep 300
    done
}

# Main execution
main() {
    initial_hash=""
    while true; do
        download_configs
        decode_configs
        compute_config_hash
        initial_hash=$(cat config_hash.txt)
        generate_xray_config
        run_xray

        # Test proxies and manage configurations
        test_proxies_every_5_minutes
        if [ $? -eq 1 ]; then
            continue  # Restart the loop if configurations have changed
        fi
    done
}

# Start the script
echo "Proxy Manager Script Starting..."
main
