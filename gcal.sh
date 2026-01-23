#!/bin/bash

# Path to your .env file
ENV_FILE="$(dirname "$0")/.env"
CAL_FILE="./calendar" # use $HOME later
TEMP_RAW="/tmp/cal_raw.txt"
TODAY=$(date +%Y%m%d)
END_DATE=$(date -d "+2 months" "+%Y%m%d" 2>/dev/null || date -v+2m "+%Y%m%d" 2>/dev/null || echo "$(date -d "$(date +%Y-%m-01) +3 months -1 day" "+%Y%m%d")")

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
    # First pass: handle line continuations (lines starting with space/tab)
    curl -s "$URL" | sed 's/\r//' | awk '
    {
        if (/^[ \t]/) {
            # Line continuation - append to previous, remove leading space
            line = prev substr($0, 2)
        } else {
            # New line - output previous if exists
            if (prev != "") print prev
            line = $0
        }
        prev = line
    }
    END {
        if (prev != "") print prev
    }' | awk '
    # Process ALL events in the .ics file, regardless of:
    # - ORGANIZER (who created the event)
    # - CREATED (when it was created)
    # - ATTENDEE (who is invited)
    # - Any other metadata fields
    # Every VEVENT block with a DTSTART will be included
    /^BEGIN:VEVENT/ {
        # Reset state for new event
        dstr = ""
        dtstart_full = ""
        dtend_full = ""
        tzid = ""
        summary = ""
        rrule = ""
    }
    /^DTSTART/ {
        # Extract timezone ID if present: TZID=TimezoneName:
        if (match($0, /TZID=/)) {
            tzid_start = RSTART + 5
            tzid_end = index(substr($0, tzid_start), ":")
            if (tzid_end > 0) {
                tzid = substr($0, tzid_start, tzid_end - 1)
            }
        }
        # Match various DTSTART formats and preserve full string
        # First try to match datetime format with T
        if (match($0, /:[0-9]{8}T[0-9]{6}Z?/)) {
            dtstart_full = substr($0, RSTART+1)
            dstr = dtstart_full
        }
        # Then try all-day format (8 digits only, no T)
        else if (match($0, /:[0-9]{8}[^0-9T]/) || match($0, /:[0-9]{8}$/)) {
            dtstart_full = substr($0, RSTART+1, 8)
            dstr = dtstart_full
        }
    }
    /^DTEND/ {
        # Extract timezone ID if present (for DTEND)
        if (match($0, /TZID=/)) {
            tzid_start = RSTART + 5
            tzid_end = index(substr($0, tzid_start), ":")
            if (tzid_end > 0) {
                # Use the same timezone as DTSTART if not already set
                if (tzid == "") {
                    tzid = substr($0, tzid_start, tzid_end - 1)
                }
            }
        }
        # Match various DTEND formats
        if (match($0, /:[0-9]{8}T[0-9]{6}Z?/)) {
            dtend_full = substr($0, RSTART+1)
        } else if (match($0, /:[0-9]{8}[^0-9T]/) || match($0, /:[0-9]{8}$/)) {
            dtend_full = substr($0, RSTART+1, 8)
        }
    }
    /^RRULE/ {
        sub(/^RRULE:/, "", $0)
        rrule = $0
    }
    /^SUMMARY/ {
        sub(/^SUMMARY[^:]*:/, "", $0)
        summary = $0
    }
    /^END:VEVENT/ {
        # Output event(s) when we reach the end
        if (dstr != "") {
            if (rrule != "") {
                # Recurring event - expand it
                print "RECURRING\t" dtstart_full "\t" dtend_full "\t" tzid "\t" rrule "\t" (summary != "" ? summary : "(No title)")
            } else {
                # Single event - include DTEND for multi-day events
                # Format: dtstart_full<TAB>dtend_full<TAB>tzid<TAB>summary
                tzid_val = (tzid != "" ? tzid : "NONE")
                dtend_val = (dtend_full != "" ? dtend_full : "NONE")
                print dtstart_full "\t" dtend_val "\t" tzid_val "\t" (summary != "" ? summary : "(No title)")
            }
        }
        # Reset for next event
        dstr = ""
        dtstart_full = ""
        dtend_full = ""
        tzid = ""
        summary = ""
        rrule = ""
    }' >> "$TEMP_RAW"
done

# 3. Process, Sort (Deduplicate), and Filter
TEMP_EXPANDED="/tmp/cal_expanded.txt"
> "$TEMP_EXPANDED"

# Function to convert date with timezone to local date
convert_date() {
    local raw_date=$1
    local tzid=$2
    
    # If it's an all-day event (8 digits only)
    if [[ ${#raw_date} -eq 8 ]]; then
        echo "$raw_date"
        return
    fi
    
    # Parse the date string
    if [[ $raw_date =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})(Z)?$ ]]; then
        year=${BASH_REMATCH[1]}
        month=${BASH_REMATCH[2]}
        day=${BASH_REMATCH[3]}
        hour=${BASH_REMATCH[4]}
        min=${BASH_REMATCH[5]}
        sec=${BASH_REMATCH[6]}
        is_utc=${BASH_REMATCH[7]}
        
        if [[ -n "$is_utc" ]]; then
            # UTC time
            date -d "${year}-${month}-${day} ${hour}:${min}:${sec} UTC" "+%Y%m%d" 2>/dev/null || echo "${year}${month}${day}"
        elif [[ -n "$tzid" ]]; then
            # Timezone specified - convert from that timezone to local
            # First, interpret the time in the given timezone, then convert to local
            TZ="$tzid" date -d "${year}-${month}-${day} ${hour}:${min}:${sec}" "+%Y%m%d" 2>/dev/null || \
            date -d "TZ=\"$tzid\" ${year}-${month}-${day} ${hour}:${min}:${sec}" "+%Y%m%d" 2>/dev/null || \
            echo "${year}${month}${day}"
        else
            # Assume local time
            date -d "${year}-${month}-${day} ${hour}:${min}:${sec}" "+%Y%m%d" 2>/dev/null || echo "${year}${month}${day}"
        fi
    else
        # Fallback: just take first 8 digits
        echo "${raw_date:0:8}"
    fi
}

# Function to expand recurring events
expand_recurrence() {
    local dtstart=$1
    local dtend=$2
    local tzid=$3
    local rrule=$4
    local summary=$5
    
    # Parse DTSTART
    if [[ $dtstart =~ ^([0-9]{4})([0-9]{2})([0-9]{2})(T([0-9]{2})([0-9]{2})([0-9]{2})(Z)?)?$ ]]; then
        year=${BASH_REMATCH[1]}
        month=${BASH_REMATCH[2]}
        day=${BASH_REMATCH[3]}
        hour=${BASH_REMATCH[5]:-00}
        min=${BASH_REMATCH[6]:-00}
        sec=${BASH_REMATCH[7]:-00}
        is_utc=${BASH_REMATCH[8]}
        
        # Parse RRULE
        freq=""
        count=""
        until_date=""
        byday=""
        interval=1
        
        IFS=';' read -ra RULE_PARTS <<< "$rrule"
        for part in "${RULE_PARTS[@]}"; do
            if [[ $part =~ ^FREQ=([A-Z]+)$ ]]; then
                freq=${BASH_REMATCH[1]}
            elif [[ $part =~ ^COUNT=([0-9]+)$ ]]; then
                count=${BASH_REMATCH[1]}
            elif [[ $part =~ ^UNTIL=([0-9TZ]+)$ ]]; then
                until_date=${BASH_REMATCH[1]}
            elif [[ $part =~ ^BYDAY=([A-Z,]+)$ ]]; then
                byday=${BASH_REMATCH[1]}
            elif [[ $part =~ ^INTERVAL=([0-9]+)$ ]]; then
                interval=${BASH_REMATCH[1]}
            fi
        done
        
        # Calculate end date (2 months from today, or until date, whichever is earlier)
        end_limit="$END_DATE"
        if [[ -n "$until_date" ]]; then
            until_date_only=${until_date:0:8}
            if [[ $until_date_only -lt "$end_limit" ]]; then
                end_limit=$until_date_only
            fi
        fi
        
        # Expand occurrences - ALWAYS expand from DTSTART, then filter
        occurrences=0
        original_start_date="${year}${month}${day}"
        current_date="$original_start_date"
        
        # For events with COUNT, calculate how many occurrences have already passed
        # (from DTSTART to TODAY) so we only expand the remaining ones
        if [[ -n "$count" ]] && [[ $current_date -lt "$TODAY" ]]; then
            # Count how many occurrences happened before TODAY
            occurrences_passed=0
            temp_date="$current_date"
            
            while [[ $temp_date -lt "$TODAY" ]] && [[ $occurrences_passed -lt $count ]]; do
                occurrences_passed=$((occurrences_passed + 1))
                
                # Calculate next occurrence based on frequency
                case "$freq" in
                    DAILY)
                        temp_date=$(date -d "${temp_date:0:4}-${temp_date:4:2}-${temp_date:6:2} +${interval} days" "+%Y%m%d" 2>/dev/null || echo "$temp_date")
                        ;;
                    WEEKLY)
                        temp_date=$(date -d "${temp_date:0:4}-${temp_date:4:2}-${temp_date:6:2} +${interval} weeks" "+%Y%m%d" 2>/dev/null || echo "$temp_date")
                        ;;
                    MONTHLY)
                        temp_date=$(date -d "${temp_date:0:4}-${temp_date:4:2}-${temp_date:6:2} +${interval} months" "+%Y%m%d" 2>/dev/null || echo "$temp_date")
                        ;;
                    YEARLY)
                        temp_date=$(date -d "${temp_date:0:4}-${temp_date:4:2}-${temp_date:6:2} +${interval} years" "+%Y%m%d" 2>/dev/null || echo "$temp_date")
                        ;;
                esac
                
                # Safety check
                if [[ ${#temp_date} -ne 8 ]] || [[ $occurrences_passed -gt 1000 ]]; then
                    break
                fi
            done
            
            # If all occurrences have passed, don't expand
            if [[ $occurrences_passed -ge $count ]]; then
                return
            fi
            
            # Adjust count to remaining occurrences
            count=$((count - occurrences_passed))
            # Start from the next occurrence (temp_date is already the next one after the last passed occurrence)
            current_date="$temp_date"
        fi
        
        # For events starting in the past (without COUNT or with remaining occurrences), fast-forward to first occurrence >= TODAY
        # This is especially important for BYDAY events
        if [[ $current_date -lt "$TODAY" ]]; then
            case "$freq" in
                WEEKLY)
                    if [[ -n "$byday" ]]; then
                        # For BYDAY, find the next occurrence of the specified day
                        # Map day abbreviations: MO=Monday, TU=Tuesday, WE=Wednesday, TH=Thursday, FR=Friday, SA=Saturday, SU=Sunday
                        day_map=""
                        if [[ $byday == *"FR"* ]]; then
                            day_map="Friday"
                        elif [[ $byday == *"MO"* ]]; then
                            day_map="Monday"
                        elif [[ $byday == *"TU"* ]]; then
                            day_map="Tuesday"
                        elif [[ $byday == *"WE"* ]]; then
                            day_map="Wednesday"
                        elif [[ $byday == *"TH"* ]]; then
                            day_map="Thursday"
                        elif [[ $byday == *"SA"* ]]; then
                            day_map="Saturday"
                        elif [[ $byday == *"SU"* ]]; then
                            day_map="Sunday"
                        fi
                        
                        if [[ -n "$day_map" ]]; then
                            # Find next occurrence of this day starting from TODAY
                            current_date=$(date -d "next $day_map" "+%Y%m%d" 2>/dev/null || echo "$TODAY")
                        else
                            # Fallback: just advance by weeks
                            days_diff=$(( ($(date -d "$TODAY" +%s 2>/dev/null || echo 0) - $(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2}" +%s 2>/dev/null || echo 0)) / 86400 ))
                            if [[ $days_diff -gt 0 ]]; then
                                weeks_to_skip=$(( (days_diff + 6) / 7 ))
                                current_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +$((weeks_to_skip * interval)) weeks" "+%Y%m%d" 2>/dev/null || echo "$TODAY")
                            fi
                        fi
                    else
                        # No BYDAY, just advance by weeks
                        days_diff=$(( ($(date -d "$TODAY" +%s 2>/dev/null || echo 0) - $(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2}" +%s 2>/dev/null || echo 0)) / 86400 ))
                        if [[ $days_diff -gt 0 ]]; then
                            weeks_to_skip=$(( (days_diff + 6) / 7 ))
                            current_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +$((weeks_to_skip * interval)) weeks" "+%Y%m%d" 2>/dev/null || echo "$TODAY")
                        fi
                    fi
                    ;;
                DAILY)
                    # Fast-forward to TODAY if in the past
                    if [[ $current_date -lt "$TODAY" ]]; then
                        current_date="$TODAY"
                    fi
                    ;;
                MONTHLY)
                    # For monthly, advance until we're at or past TODAY
                    while [[ $current_date -lt "$TODAY" ]]; do
                        current_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +${interval} months" "+%Y%m%d" 2>/dev/null || echo "$TODAY")
                        if [[ $current_date == "$TODAY" ]] || [[ ${#current_date} -ne 8 ]]; then
                            break
                        fi
                    done
                    ;;
            esac
        fi
        
        # Now expand all occurrences from current_date forward
        while [[ $current_date -le "$end_limit" ]]; do
            # Check limits
            if [[ -n "$count" ]] && [[ $occurrences -ge $count ]]; then
                break
            fi
            if [[ -n "$until_date" ]] && [[ $current_date -gt "${until_date:0:8}" ]]; then
                break
            fi
            
            # Convert to local date and only output if within the 2-month window (filter AFTER expansion)
            local_date=$(convert_date "${current_date}${hour}${min}${sec}" "$tzid")
            if [[ -n "$local_date" ]] && [[ $local_date -ge "$TODAY" ]] && [[ $local_date -le "$END_DATE" ]]; then
                echo -e "${local_date}\t${summary}"
            fi
            
            occurrences=$((occurrences + 1))
            
            # Calculate next occurrence based on frequency
            case "$freq" in
                DAILY)
                    current_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +${interval} days" "+%Y%m%d" 2>/dev/null || echo "$current_date")
                    ;;
                WEEKLY)
                    if [[ -n "$byday" ]]; then
                        # For BYDAY, advance by interval weeks (the day will be correct)
                        current_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +${interval} weeks" "+%Y%m%d" 2>/dev/null || echo "$current_date")
                    else
                        current_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +${interval} weeks" "+%Y%m%d" 2>/dev/null || echo "$current_date")
                    fi
                    ;;
                MONTHLY)
                    current_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +${interval} months" "+%Y%m%d" 2>/dev/null || echo "$current_date")
                    ;;
                YEARLY)
                    current_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +${interval} years" "+%Y%m%d" 2>/dev/null || echo "$current_date")
                    ;;
                *)
                    # Unknown frequency, stop
                    break
                    ;;
            esac
            
            # Safety check to prevent infinite loops
            if [[ $occurrences -gt 1000 ]]; then
                break
            fi
        done
    fi
}

# Process events
while IFS=$'\t' read -r line || [[ -n "$line" ]]; do
    # Skip empty lines
    [[ -z "$line" ]] && continue
    
    if [[ $line =~ ^RECURRING ]]; then
        # Recurring event - format: RECURRING<TAB>dtstart<TAB>dtend<TAB>tzid<TAB>rrule<TAB>summary
        IFS=$'\t' read -r _ dtstart dtend tzid rrule summary <<< "$line"
        [[ "$dtend" == "NONE" ]] && dtend=""
        expand_recurrence "$dtstart" "$dtend" "$tzid" "$rrule" "$summary" >> "$TEMP_EXPANDED"
    else
        # Single event - format: dtstart_full<TAB>dtend_full<TAB>tzid<TAB>summary
        IFS=$'\t' read -r raw_date dtend_date tzid summary <<< "$line"
        
        # Handle placeholders
        [[ "$tzid" == "NONE" ]] && tzid=""
        [[ "$dtend_date" == "NONE" ]] && dtend_date=""
        
        # Skip if no date
        [[ -z "$raw_date" ]] && continue
        
        # Convert start and end dates
        local_start=$(convert_date "$raw_date" "$tzid")
        local_end=""
        if [[ -n "$dtend_date" ]]; then
            local_end=$(convert_date "$dtend_date" "$tzid")
        fi
        
        # For multi-day events, check if event spans into our date range
        # Include if: start is in range, OR end is in range, OR event spans across our range
        should_include=false
        
        # Check if start date is in range (including today)
        if [[ -n "$local_start" ]] && [[ $local_start -ge "$TODAY" ]] && [[ $local_start -le "$END_DATE" ]]; then
            should_include=true
        # Check if end date is in range (including today)
        elif [[ -n "$local_end" ]] && [[ "$local_end" != "NONE" ]] && [[ $local_end -ge "$TODAY" ]] && [[ $local_end -le "$END_DATE" ]]; then
            should_include=true
        # Check if event spans across our range (starts before today, ends today or later)
        elif [[ -n "$local_start" ]] && [[ -n "$local_end" ]] && [[ "$local_end" != "NONE" ]]; then
            if [[ $local_start -le "$TODAY" ]] && [[ $local_end -ge "$TODAY" ]]; then
                should_include=true
            fi
        # Fallback: if we only have a start date and it's today or later
        elif [[ -n "$local_start" ]] && [[ $local_start -ge "$TODAY" ]]; then
            should_include=true
        fi
        
        if [[ "$should_include" == true ]]; then
            # For multi-day events, output on each day they span (within our range)
            # Check if it's truly multi-day (different dates, not just different times on same day)
            if [[ -n "$local_end" ]] && [[ "$local_end" != "NONE" ]] && [[ $local_end -gt "$local_start" ]]; then
                # Multi-day event - show on each day
                current_day="$local_start"
                # Don't go beyond END_DATE
                max_day="$local_end"
                if [[ $max_day -gt "$END_DATE" ]]; then
                    max_day="$END_DATE"
                fi
                # Start from TODAY if event started in the past
                if [[ $current_day -lt "$TODAY" ]]; then
                    current_day="$TODAY"
                fi
                
                while [[ $current_day -le "$max_day" ]]; do
                    echo -e "${current_day}\t${summary}" >> "$TEMP_EXPANDED"
                    # Move to next day
                    current_day=$(date -d "${current_day:0:4}-${current_day:4:2}-${current_day:6:2} +1 day" "+%Y%m%d" 2>/dev/null || echo "$current_day")
                    # Safety check
                    if [[ ${#current_day} -ne 8 ]]; then
                        break
                    fi
                done
            else
                # Single-day event (or same-day event with start/end times)
                echo -e "${local_start}\t${summary}" >> "$TEMP_EXPANDED"
            fi
        fi
    fi
done < "$TEMP_RAW"

# Sort, deduplicate (only true duplicates), and format
# Use sort -n | uniq instead of sort -u -n to properly handle multiple events per day
sort -n "$TEMP_EXPANDED" | uniq | awk -F'\t' '{
    month = substr($1, 5, 2) + 0;
    day   = substr($1, 7, 2) + 0;
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ");
    print m[month] " " day "\t" $2;
}' > "$CAL_FILE"

# Debug: Check if specific events are in the raw data
if [[ "${DEBUG:-}" == "1" ]]; then
    echo ""
    echo "=== DEBUG: Checking for specific events ==="
    echo "TODAY: $TODAY"
    echo "END_DATE: $END_DATE"
    echo ""
    echo "Looking for 'Test':"
    grep -i "test" "$TEMP_RAW" | head -3 || echo "  Not found in raw data"
    echo ""
    echo "Looking for 'Gaelle':"
    grep -i "gaelle" "$TEMP_RAW" | head -3 || echo "  Not found in raw data"
    echo ""
    echo "Looking for 'CLEM' or 'SOCCER':"
    grep -i "clem\|soccer" "$TEMP_RAW" | head -3 || echo "  Not found in raw data"
    echo ""
    echo "Total events in raw data: $(wc -l < "$TEMP_RAW" 2>/dev/null || echo 0)"
    echo "Total events after processing: $(wc -l < "$TEMP_EXPANDED" 2>/dev/null || echo 0)"
    echo ""
    echo "First 5 events in raw data:"
    head -5 "$TEMP_RAW" 2>/dev/null || echo "  No raw data"
    echo ""
    echo "First 5 events after processing:"
    head -5 "$TEMP_EXPANDED" 2>/dev/null || echo "  No processed data"
    # Keep temp files for inspection
    echo "Raw data kept at: $TEMP_RAW"
    echo "Processed data kept at: $TEMP_EXPANDED"
else
    rm -f "$TEMP_RAW" "$TEMP_EXPANDED"
fi
echo "Sync complete!"
