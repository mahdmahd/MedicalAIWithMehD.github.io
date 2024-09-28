#!/bin/bash

# ==========================================
# Proxy Testing and Configuration Script
# ==========================================
#
# This script performs the following actions:
# 1. Downloads configuration files from GitHub.
# 2. Starts the xray_softfloat binary with the downloaded configuration.
# 3. Tests proxy ports periodically to identify the best-performing proxies.
# 4. Encodes results to Base64.
# 5. Checks for configuration updates and restarts the process if updates are found.
#
# ==========================================

# ---------------------------
# Configuration Variables
# ---------------------------

# Replace 'mytoken' with your actual GitHub token
GITHUB_TOKEN=""

# GitHub URLs for the configuration files
CONFIG_URL="https://raw.githubusercontent.com/mahdmahd/configSpeedtest/refs/heads/main/configSpeedtest.json"
PROXYCOUNT_URL="https://raw.githubusercontent.com/mahdmahd/configSpeedtest/refs/heads/main/proxyCount.txt"

# Directory to save Base64 encoded files
BASE_DIRECTORY="/c/Users/mehdi/Desktop/gitdecode"  # Adjust for your environment

# URL to test proxy speed
TEST_URL="https://vimeo.com/946171968"

# Interval settings
SLEEP_INTERVAL=900  # 5 minutes in seconds

# ---------------------------
# Function Definitions
# ---------------------------

# Function to download configuration files from GitHub
download_configs() {
    echo "Downloading configSpeedtest.json..."
    curl -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3.raw" \
         -o configSpeedtest.json "$CONFIG_URL"
    if [ $? -ne 0 ]; then
        echo "Failed to download configSpeedtest.json. Exiting."
        exit 1
    fi

    echo "Downloading proxyCount.txt..."
    curl -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3.raw" \
         -o proxyCount.txt "$PROXYCOUNT_URL"
    if [ $? -ne 0 ]; then
        echo "Failed to download proxyCount.txt. Exiting."
        exit 1
    fi

    echo "Configurations downloaded successfully."
}

# Function to encode a file to Base64
encode_file_base64() {
    local input_file="$1"
    local output_file="$2"

    echo "Encoding $input_file to Base64..."
    base64 "$input_file" > "$output_file"
    if [ $? -eq 0 ]; then
        echo "Successfully encoded $input_file to $output_file."
    else
        echo "Error encoding $input_file to Base64."
    fi
}

# Function to test proxies with a specified timeout
test_proxies() {
    local timeout=$1
    shift
    local proxy_list=("$@")
    local response_time
    local valid_ports=()

    for port in "${proxy_list[@]}"; do
        echo "Testing proxy on port $port with timeout ${timeout}s..."
        # Execute curl to measure response time
        response=$(curl --socks5 "127.0.0.1:$port" \
                        -o /dev/null \
                        -s \
                        -w "%{time_total}" \
                        --max-time "$timeout" \
                        "$TEST_URL")
        exit_status=$?
        if [ $exit_status -eq 43 ]; then
            # Remove any surrounding quotes from the response
            response_time=$(echo "$response" | tr -d '"')
            # Compare response time with timeout using bc for floating-point comparison
            is_less=$(echo "$response_time < $timeout" | bc)
            if [ "$is_less" -eq 1 ]; then
                echo "Port $port responded in $response_time seconds."
                valid_ports+=("$port:$response_time")
            else
                echo "Port $port response time $response_time exceeds timeout. Skipping."
            fi
        else
            echo "Port $port failed with exit code $exit_status. Skipping."
        fi
    done

    # Sort the valid ports based on response time (ascending)
    sorted_ports=$(printf '%s\n' "${valid_ports[@]}" | sort -t ':' -k2 -n)

    # Extract only the port numbers from the sorted list
    sorted_only_ports=()
    while IFS= read -r line; do
        port=$(echo "$line" | cut -d':' -f1)
        sorted_only_ports+=("$port")
    done <<< "$sorted_ports"

    echo "Valid ports after sorting:"
    printf '%s\n' "${sorted_only_ports[@]}"

    echo "${sorted_only_ports[@]}"
}


# Function to copy configSpeedtest.json to multiple config files for top ports
copy_configs_for_top_ports() {
    local top_ports=("$@")
    for i in "${!top_ports[@]}"; do
        local port=${top_ports[$i]}
        local config_filename="config$((i + 1)).json"
        echo "Copying configSpeedtest.json for port $port to $config_filename..."
        cp configSpeedtest.json "$config_filename"
        if [ $? -eq 0 ]; then
            echo "Successfully copied to $config_filename."
        else
            echo "Error copying to $config_filename."
        fi
    done
}

# ---------------------------
# Initial Setup
# ---------------------------

# Create the base directory if it doesn't exist
mkdir -p "$BASE_DIRECTORY"

# Download the initial configuration files
download_configs


# Start the xray_softfloat binary with the configuration file
echo "Starting xray_softfloat with configSpeedtest.json..."
./xray_softfloat -config configSpeedtest.json &
XRAY_PID=$!
echo "xray_softfloat started with PID $XRAY_PID."

# ---------------------------
# Main Loop
# ---------------------------

while true; do
    echo "--------------------------------------------"
    echo "Starting a new proxy testing cycle at $(date)"
    echo "--------------------------------------------"

    # Read proxy ports from proxyCount.txt into an array
    mapfile -t proxy_ports < proxyCount.txt

    if [ ${#proxy_ports[@]} -eq 0 ]; then
        echo "No proxy ports found in proxyCount.txt. Skipping this cycle."
    else
        # ---------------------------
        # First Round of Proxy Testing
        # ---------------------------
        echo "First round of proxy tests..."
        first_round_ports=$(test_proxies 1 "${proxy_ports[@]}")

        # Convert the space-separated ports into an array
        IFS=' ' read -r -a first_round_array <<< "$first_round_ports"

        # Save the first-round best ports to best.txt
        echo "Saving first-round best ports to best.txt..."
        > best.txt  # Truncate or create the file
        for port in "${first_round_array[@]}"; do
            echo "http://127.0.0.1:$port" >> best.txt
        done
        echo "First-round best ports saved to best.txt."

        # Encode best.txt to Base64 and save to BASE_DIRECTORY
        encode_file_base64 "best.txt" "$BASE_DIRECTORY/best64.txt"

        # ---------------------------
        # Second Round of Proxy Testing
        # ---------------------------
        echo "Second round of proxy tests on top ports..."
        second_round_ports=$(test_proxies 1 "${first_round_array[@]}")

        # Convert the space-separated ports into an array
        IFS=' ' read -r -a second_round_array <<< "$second_round_ports"

        # Save the second-round top ports to best_inloop.txt
        echo "Saving second-round top ports to best_inloop.txt..."
        > best_inloop.txt  # Truncate or create the file
        for port in "${second_round_array[@]}"; do
            echo "http://127.0.0.1:$port" >> best_inloop.txt
        done
        echo "Second-round top ports saved to best_inloop.txt."

        # Encode best_inloop.txt to Base64 and save to BASE_DIRECTORY
        encode_file_base64 "best_inloop.txt" "$BASE_DIRECTORY/best_inloop64.txt"

        # ---------------------------
        # Copy Configuration Files for Top Ports
        # ---------------------------
        echo "Copying configuration files for top ports..."
        copy_configs_for_top_ports "${second_round_array[@]}"
    # ---------------------------
    # Wait Before Next Cycle
    # ---------------------------
    echo "Cycle complete. Sleeping for 5 minutes before the next test."
    sleep "$SLEEP_INTERVAL"
done
