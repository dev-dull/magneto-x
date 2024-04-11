#!/bin/bash

current_version=$(cat version.txt)

new_version=$(curl -s http://127.0.0.1:8880/get_os_version | jq -r '.version')
new_version_number=$(echo $new_version | cut -d '-' -f 4)

if [[ "$new_version_number" > "$current_version" ]]; then
    echo "Current version $current_version ，New version is $new_version_number , updating now"
elif [[ "$new_version_number" < "$current_version" ]]; then
    echo "Current version $current_version New version is  $new_version_number ,no need update"
else
    echo "Current version $current_version New version is  $new_version_number , no need update"
fi
