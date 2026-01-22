#!/bin/bash

# Path to your .env file
ENV_FILE="$(dirname "$0")/.env"
CAL_FILE="./calendar" # use $HOME later
TEMP_RAW="/tmp/cal_raw.txt"
TODAY=$(date +%Y%m%d)

# 1. Load the .env file
if [ -f "$ENV_FILE" ]; then
    # We source it to bring CAL_URLS into the environment
    source "$ENV_FILE"
else
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

> "$TEMP_RAW"

# 2. Loop through the URLs (Shell treats the spaces/newlines as separators)
for URL in $CAL_URLS; do
    # Skip empty lines or comments
    [[ -z "$URL" || "$URL" == \#* ]] && continue

    echo "Fetching: $URL"
    curl -s "$URL" | sed 's/\r//' | awk '
    /^DTSTART/ {
        match($0, /[0-9]{8}T[0-9]{6}Z/);
        if (RSTART > 0) dstr = substr($0, RSTART, 16);
        else {
            match($0, /[0-9]{8}/);
            dstr = substr($0, RSTART, 8);
        }
    }
    /^SUMMARY/ {
        sub(/^SUMMARY:/, "", $0);
        if (dstr != "") { print dstr "\t" $0; dstr=""; }
    }' >> "$TEMP_RAW"
done

# 3. Process, Sort (Deduplicate), and Filter
cat "$TEMP_RAW" | while IFS=$'\t' read -r raw_date summary; do
    local_val=$(date -d "$(echo $raw_date | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)T\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)Z/\1-\2-\3 \4:\5:\6 UTC/')" "+%Y%m%d" 2>/dev/null)
    [ -z "$local_val" ] && local_val=$(echo $raw_date | cut -c1-8)

    if [ "$local_val" -ge "$TODAY" ]; then
        echo -e "${local_val}\t${summary}"
    fi
done | sort -u -n | awk -F'\t' '{
    month = substr($1, 5, 2) + 0;
    day   = substr($1, 7, 2) + 0;
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ");
    print m[month] " " day "\t" $2;
}' > "$CAL_FILE"

rm "$TEMP_RAW"
echo "Sync complete!"
