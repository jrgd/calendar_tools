#!/bin/bash

# Path to your .env file
ENV_FILE="$(dirname "$0")/.env"
CAL_FILE="./calendar" # use $HOME later
TEMP_RAW="/tmp/cal_raw.txt"
TODAY=$(date +%Y%m%d)
NOW_TIME=$(date +%H:%M)
END_DATE=$(date -d "$TODAY +2 months" "+%Y%m%d")
# Default start time for multi-day events on days after the first day
DAY_START_TIME="${DAY_START_TIME:-07:00}"

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
    i=$((i+1))
    echo "Fetching url $i"
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

# Function to convert time with timezone to local time (returns HH:MM)
convert_time() {
    local raw_date=$1
    local tzid=$2
    
    # If it's an all-day event (8 digits only), return empty
    if [[ ${#raw_date} -eq 8 ]]; then
        echo ""
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
            # UTC time - convert to local time
            date -d "${year}-${month}-${day} ${hour}:${min}:${sec} UTC" "+%H:%M" 2>/dev/null || echo ""
        elif [[ -n "$tzid" ]]; then
            # Timezone specified - convert from that timezone to local
            TZ="$tzid" date -d "${year}-${month}-${day} ${hour}:${min}:${sec}" "+%H:%M" 2>/dev/null || \
            date -d "TZ=\"$tzid\" ${year}-${month}-${day} ${hour}:${min}:${sec}" "+%H:%M" 2>/dev/null || \
            echo ""
        else
            # Assume local time
            date -d "${year}-${month}-${day} ${hour}:${min}:${sec}" "+%H:%M" 2>/dev/null || echo ""
        fi
    else
        # Fallback: empty
        echo ""
    fi
}

# Function to check if event is still ongoing (not finished)
# Returns 0 (true) if event should be kept, 1 (false) if it should be filtered out
is_event_ongoing() {
    local event_date=$1  # YYYYMMDD format
    local end_datetime=$2  # Full datetime string (YYYYMMDDTHHMMSS or YYYYMMDD)
    local tzid=$3
    
    # If event is not today, keep it
    if [[ $event_date != "$TODAY" ]]; then
        return 0
    fi
    
    # If no end time specified (all-day or no DTEND), keep it
    if [[ -z "$end_datetime" ]] || [[ "$end_datetime" == "NONE" ]] || [[ ${#end_datetime} -eq 8 ]]; then
        return 0
    fi
    
    # Get end time in local timezone
    local end_time=$(convert_time "$end_datetime" "$tzid")
    
    # If we couldn't get end time, keep the event (better safe than sorry)
    if [[ -z "$end_time" ]]; then
        return 0
    fi
    
    # Compare current time with end time
    # Convert to minutes since midnight for comparison
    current_minutes=$(date -d "$(date +%Y-%m-%d) $NOW_TIME" +%s 2>/dev/null || echo 0)
    end_minutes=$(date -d "$(date +%Y-%m-%d) $end_time" +%s 2>/dev/null || echo 0)
    
    # If current time is past end time, filter it out (return 1)
    if [[ $current_minutes -gt $end_minutes ]]; then
        return 1
    fi
    
    # Event is still ongoing, keep it (return 0)
    return 0
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
                    if [[ -n "$byday" ]] && [[ $byday =~ ^([1-5])([A-Z]{2})$ ]]; then
                        # MONTHLY with BYDAY - find next occurrence of Nth day
                        occurrence_num=${BASH_REMATCH[1]}
                        day_abbr=${BASH_REMATCH[2]}
                        day_name=""
                        case "$day_abbr" in
                            MO) day_name="Monday" ;;
                            TU) day_name="Tuesday" ;;
                            WE) day_name="Wednesday" ;;
                            TH) day_name="Thursday" ;;
                            FR) day_name="Friday" ;;
                            SA) day_name="Saturday" ;;
                            SU) day_name="Sunday" ;;
                        esac
                        if [[ -n "$day_name" ]]; then
                            # Find the Nth occurrence of the day in the current month or next month
                            # Map day name to day number (1=Monday, 7=Sunday)
                            day_num=1
                            case "$day_name" in
                                Monday) day_num=1 ;;
                                Tuesday) day_num=2 ;;
                                Wednesday) day_num=3 ;;
                                Thursday) day_num=4 ;;
                                Friday) day_num=5 ;;
                                Saturday) day_num=6 ;;
                                Sunday) day_num=7 ;;
                            esac
                            
                            # Try current month first
                            current_month=$(date -d "$TODAY" "+%Y-%m-01" 2>/dev/null)
                            if [[ -n "$current_month" ]]; then
                                # Get day of week of first day of month (1=Mon, 7=Sun)
                                first_day_dow=$(date -d "$current_month" +%u 2>/dev/null || echo 1)
                                # Calculate days to first occurrence of target day
                                if [[ $first_day_dow -le $day_num ]]; then
                                    days_to_first=$((day_num - first_day_dow))
                                else
                                    days_to_first=$((7 - first_day_dow + day_num))
                                fi
                                first_occurrence=$(date -d "$current_month +${days_to_first} days" "+%Y%m%d" 2>/dev/null)
                                if [[ -n "$first_occurrence" ]]; then
                                    nth_occurrence_current=$(date -d "${first_occurrence:0:4}-${first_occurrence:4:2}-${first_occurrence:6:2} +$((occurrence_num - 1)) weeks" "+%Y%m%d" 2>/dev/null)
                                    # If this month's occurrence is today or in the future, use it
                                    # IMPORTANT: Always use nth_occurrence_current if it's >= TODAY, even if it's exactly TODAY
                                    if [[ -n "$nth_occurrence_current" ]] && [[ $nth_occurrence_current -ge "$TODAY" ]]; then
                                        # Force set current_date to the calculated nth occurrence
                                        current_date="$nth_occurrence_current"
                                    else
                                        # Try next month
                                        next_month=$(date -d "$current_month +${interval} months" "+%Y-%m-01" 2>/dev/null)
                                        if [[ -n "$next_month" ]]; then
                                            first_day_dow=$(date -d "$next_month" +%u 2>/dev/null || echo 1)
                                            if [[ $first_day_dow -le $day_num ]]; then
                                                days_to_first=$((day_num - first_day_dow))
                                            else
                                                days_to_first=$((7 - first_day_dow + day_num))
                                            fi
                                            first_occurrence_next=$(date -d "$next_month +${days_to_first} days" "+%Y%m%d" 2>/dev/null)
                                            if [[ -n "$first_occurrence_next" ]]; then
                                                nth_occurrence_next=$(date -d "${first_occurrence_next:0:4}-${first_occurrence_next:4:2}-${first_occurrence_next:6:2} +$((occurrence_num - 1)) weeks" "+%Y%m%d" 2>/dev/null)
                                                if [[ -n "$nth_occurrence_next" ]]; then
                                                    current_date="$nth_occurrence_next"
                                                fi
                                            fi
                                        fi
                                    fi
                                    # Final fallback: ensure current_date is set and >= TODAY
                                    # Only use this if current_date wasn't set above (shouldn't happen if logic above worked)
                                    if [[ $current_date -lt "$TODAY" ]]; then
                                        # This should only happen if the conditions above didn't set current_date
                                        # Use the calculated nth_occurrence from current month if it exists and is valid
                                        if [[ -n "$nth_occurrence_current" ]] && [[ $nth_occurrence_current -ge "$TODAY" ]]; then
                                            current_date="$nth_occurrence_current"
                                        elif [[ -n "$nth_occurrence_next" ]] && [[ $nth_occurrence_next -ge "$TODAY" ]]; then
                                            current_date="$nth_occurrence_next"
                                        fi
                                    fi
                                    # Final safeguard: if nth_occurrence_current is valid and >= TODAY, use it
                                    # This ensures we always use the calculated date, even if something went wrong above
                                    if [[ -n "$nth_occurrence_current" ]] && [[ $nth_occurrence_current -ge "$TODAY" ]]; then
                                        current_date="$nth_occurrence_current"
                                    elif [[ -n "$nth_occurrence_next" ]] && [[ $nth_occurrence_next -ge "$TODAY" ]]; then
                                        current_date="$nth_occurrence_next"
                                    fi
                                fi
                            fi
                        else
                            # Fallback: just advance by months (shouldn't happen if BYDAY parsing worked)
                            while [[ $current_date -lt "$TODAY" ]]; do
                                next_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +${interval} months" "+%Y%m%d" 2>/dev/null)
                                if [[ -n "$next_date" ]] && [[ ${#next_date} -eq 8 ]] && [[ $next_date -ge "$TODAY" ]]; then
                                    current_date="$next_date"
                                    break
                                elif [[ -n "$next_date" ]] && [[ ${#next_date} -eq 8 ]]; then
                                    current_date="$next_date"
                                else
                                    break
                                fi
                            done
                        fi
                    else
                        # No BYDAY, just advance by months
                        while [[ $current_date -lt "$TODAY" ]]; do
                            next_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +${interval} months" "+%Y%m%d" 2>/dev/null)
                            if [[ -n "$next_date" ]] && [[ ${#next_date} -eq 8 ]] && [[ $next_date -ge "$TODAY" ]]; then
                                current_date="$next_date"
                                break
                            elif [[ -n "$next_date" ]] && [[ ${#next_date} -eq 8 ]]; then
                                current_date="$next_date"
                            else
                                break
                            fi
                        done
                    fi
                    ;;
            esac
        fi
        
        # For MONTHLY with BYDAY, ALWAYS recalculate the first occurrence to ensure correctness
        # The fast-forward may have failed or set an incorrect date, so we recalculate here
        if [[ "$freq" == "MONTHLY" ]] && [[ -n "$byday" ]] && [[ $byday =~ ^([1-5])([A-Z]{2})$ ]]; then
            occurrence_num=${BASH_REMATCH[1]}
            day_abbr=${BASH_REMATCH[2]}
            day_name=""
            case "$day_abbr" in
                MO) day_name="Monday" ;;
                TU) day_name="Tuesday" ;;
                WE) day_name="Wednesday" ;;
                TH) day_name="Thursday" ;;
                FR) day_name="Friday" ;;
                SA) day_name="Saturday" ;;
                SU) day_name="Sunday" ;;
            esac
            if [[ -n "$day_name" ]]; then
                day_num=1
                case "$day_name" in
                    Monday) day_num=1 ;;
                    Tuesday) day_num=2 ;;
                    Wednesday) day_num=3 ;;
                    Thursday) day_num=4 ;;
                    Friday) day_num=5 ;;
                    Saturday) day_num=6 ;;
                    Sunday) day_num=7 ;;
                esac
                # Always calculate the Nth occurrence of the current month (or next if current month's has passed)
                current_month=$(date -d "$TODAY" "+%Y-%m-01" 2>/dev/null)
                if [[ -n "$current_month" ]]; then
                    first_day_dow=$(date -d "$current_month" +%u 2>/dev/null || echo 1)
                    if [[ $first_day_dow -le $day_num ]]; then
                        days_to_first=$((day_num - first_day_dow))
                    else
                        days_to_first=$((7 - first_day_dow + day_num))
                    fi
                    first_occurrence=$(date -d "$current_month +${days_to_first} days" "+%Y%m%d" 2>/dev/null)
                    if [[ -n "$first_occurrence" ]]; then
                        nth_occurrence=$(date -d "${first_occurrence:0:4}-${first_occurrence:4:2}-${first_occurrence:6:2} +$((occurrence_num - 1)) weeks" "+%Y%m%d" 2>/dev/null)
                        # Use this month's occurrence if it's >= TODAY, otherwise try next month
                        if [[ -n "$nth_occurrence" ]] && [[ $nth_occurrence -ge "$TODAY" ]]; then
                            # Force set current_date to the calculated nth occurrence
                            current_date="$nth_occurrence"
                        else
                            # Try next month
                            next_month=$(date -d "$current_month +${interval} months" "+%Y-%m-01" 2>/dev/null)
                            if [[ -n "$next_month" ]]; then
                                first_day_dow=$(date -d "$next_month" +%u 2>/dev/null || echo 1)
                                if [[ $first_day_dow -le $day_num ]]; then
                                    days_to_first=$((day_num - first_day_dow))
                                else
                                    days_to_first=$((7 - first_day_dow + day_num))
                                fi
                                first_occurrence_next=$(date -d "$next_month +${days_to_first} days" "+%Y%m%d" 2>/dev/null)
                                if [[ -n "$first_occurrence_next" ]]; then
                                    nth_occurrence_next=$(date -d "${first_occurrence_next:0:4}-${first_occurrence_next:4:2}-${first_occurrence_next:6:2} +$((occurrence_num - 1)) weeks" "+%Y%m%d" 2>/dev/null)
                                    if [[ -n "$nth_occurrence_next" ]]; then
                                        # Force set current_date to the calculated nth occurrence of next month
                                        current_date="$nth_occurrence_next"
                                    fi
                                fi
                            fi
                        fi
                        # Final safeguard: if we calculated nth_occurrence for current month and it's valid, use it
                        if [[ -z "$current_date" ]] || [[ $current_date -lt "$TODAY" ]]; then
                            if [[ -n "$nth_occurrence" ]] && [[ $nth_occurrence -ge "$TODAY" ]]; then
                                current_date="$nth_occurrence"
                            elif [[ -n "$nth_occurrence_next" ]] && [[ $nth_occurrence_next -ge "$TODAY" ]]; then
                                current_date="$nth_occurrence_next"
                            fi
                        fi
                    fi
                fi
            fi
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
            # For MONTHLY BYDAY events, ALWAYS recalculate the date from current_date's month
            # This ensures we always use the correct calculated date, not just current_date directly
            local_date=""
            # For MONTHLY BYDAY events, always recalculate the date from current_date's month
            # This is critical because the day number changes each month (e.g., 4th Sunday can be 22nd, 25th, 26th, etc.)
            if [[ "$freq" == "MONTHLY" ]] && [[ -n "$byday" ]] && [[ $byday =~ ^([1-5])([A-Z]{2})$ ]]; then
                occurrence_num=${BASH_REMATCH[1]}
                day_abbr=${BASH_REMATCH[2]}
                day_name=""
                case "$day_abbr" in
                    MO) day_name="Monday" ;;
                    TU) day_name="Tuesday" ;;
                    WE) day_name="Wednesday" ;;
                    TH) day_name="Thursday" ;;
                    FR) day_name="Friday" ;;
                    SA) day_name="Saturday" ;;
                    SU) day_name="Sunday" ;;
                esac
                if [[ -n "$day_name" ]]; then
                    day_num=1
                    case "$day_name" in
                        Monday) day_num=1 ;;
                        Tuesday) day_num=2 ;;
                        Wednesday) day_num=3 ;;
                        Thursday) day_num=4 ;;
                        Friday) day_num=5 ;;
                        Saturday) day_num=6 ;;
                        Sunday) day_num=7 ;;
                    esac
                    # Only recalculate for the first occurrence
                    # For subsequent occurrences, the expansion loop already calculated the correct date in current_date
                    if [[ $occurrences -eq 0 ]]; then
                        # First occurrence - use TODAY's month to get the correct first date
                        target_month=$(date -d "$TODAY" "+%Y-%m-01" 2>/dev/null)
                    else
                        # Subsequent occurrences - skip recalculation, will use current_date directly below
                        target_month=""
                    fi
                    if [[ -n "$target_month" ]]; then
                        first_day_dow=$(date -d "$target_month" +%u 2>/dev/null || echo 1)
                        if [[ $first_day_dow -le $day_num ]]; then
                            days_to_first=$((day_num - first_day_dow))
                        else
                            days_to_first=$((7 - first_day_dow + day_num))
                        fi
                        first_occurrence=$(date -d "$target_month +${days_to_first} days" "+%Y%m%d" 2>/dev/null)
                        if [[ -n "$first_occurrence" ]]; then
                            nth_occurrence=$(date -d "${first_occurrence:0:4}-${first_occurrence:4:2}-${first_occurrence:6:2} +$((occurrence_num - 1)) weeks" "+%Y%m%d" 2>/dev/null)
                            # Always use the calculated nth_occurrence if it exists and is >= TODAY
                            # This ensures we use the correct date, not whatever current_date was set to
                            if [[ -n "$nth_occurrence" ]]; then
                                # Only use it if it's >= TODAY (don't show past occurrences)
                                if [[ $nth_occurrence -ge "$TODAY" ]]; then
                                    # Force set local_date to the calculated value - this is the correct date
                                    local_date="$nth_occurrence"
                                    # Update current_date to the calculated date so expansion loop can use it
                                    current_date="$nth_occurrence"
                                fi
                            fi
                        fi
                    fi
                fi
            fi
            
            # If local_date wasn't set by first occurrence check, use current_date directly
            # For MONTHLY BYDAY events, the expansion loop already calculated the correct date in current_date
            # So we should use current_date directly, not recalculate
            if [[ -z "$local_date" ]]; then
                # Check if this is an all-day event (8-digit date, no time)
                if [[ ${#dtstart} -eq 8 ]]; then
                    # All-day event - use date directly
                    local_date="$current_date"
                else
                    # Timed event - build datetime string with T separator: YYYYMMDDTHHMMSS
                    datetime_str="${current_date}T${hour}${min}${sec}"
                    local_date=$(convert_date "$datetime_str" "$tzid")
                fi
            fi
            
            if [[ -n "$local_date" ]] && [[ $local_date -ge "$TODAY" ]] && [[ $local_date -le "$END_DATE" ]]; then
                # Check if event is still ongoing (not finished if it's today)
                # For all-day events, always keep them (no end time to check)
                if [[ ${#dtstart} -eq 8 ]] || is_event_ongoing "$local_date" "$dtend" "$tzid"; then
                    # Get the time in local timezone (only for timed events)
                    if [[ ${#dtstart} -eq 8 ]]; then
                        # All-day event - no time
                        echo -e "${local_date}\t${summary}"
                    else
                        local_time=$(convert_time "$datetime_str" "$tzid")
                        if [[ -n "$local_time" ]]; then
                            echo -e "${local_date}\t${summary}, ${local_time}"
                        else
                            echo -e "${local_date}\t${summary}"
                        fi
                    fi
                fi
            fi
            
            occurrences=$((occurrences + 1))
            
            # Calculate next occurrence based on frequency
            # For MONTHLY BYDAY, this will recalculate current_date for the next month
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
                    if [[ -n "$byday" ]]; then
                        # Parse BYDAY format: 1MO, 2TU, 4SU, etc. or just MO, TU, etc.
                        # Extract occurrence number (1-5) and day
                        if [[ $byday =~ ^([1-5])([A-Z]{2})$ ]]; then
                            occurrence_num=${BASH_REMATCH[1]}
                            day_abbr=${BASH_REMATCH[2]}
                            
                            # Map day abbreviations to day names
                            day_name=""
                            case "$day_abbr" in
                                MO) day_name="Monday" ;;
                                TU) day_name="Tuesday" ;;
                                WE) day_name="Wednesday" ;;
                                TH) day_name="Thursday" ;;
                                FR) day_name="Friday" ;;
                                SA) day_name="Saturday" ;;
                                SU) day_name="Sunday" ;;
                            esac
                            
                            if [[ -n "$day_name" ]]; then
                                # For MONTHLY with BYDAY, we MUST recalculate the Nth occurrence for the next month
                                # We can't just add a month because the day number will be different each month
                                # Move to next month
                                next_month=$(date -d "${current_date:0:4}-${current_date:4:2}-01 +${interval} months" "+%Y-%m-01" 2>/dev/null)
                                if [[ -n "$next_month" ]]; then
                                    # Map day name to day number (1=Monday, 7=Sunday)
                                    day_num=1
                                    case "$day_name" in
                                        Monday) day_num=1 ;;
                                        Tuesday) day_num=2 ;;
                                        Wednesday) day_num=3 ;;
                                        Thursday) day_num=4 ;;
                                        Friday) day_num=5 ;;
                                        Saturday) day_num=6 ;;
                                        Sunday) day_num=7 ;;
                                    esac
                                    # Get day of week of first day of next month
                                    first_day_dow=$(date -d "$next_month" +%u 2>/dev/null || echo 1)
                                    # Calculate days to first occurrence of target day in next month
                                    if [[ $first_day_dow -le $day_num ]]; then
                                        days_to_first=$((day_num - first_day_dow))
                                    else
                                        days_to_first=$((7 - first_day_dow + day_num))
                                    fi
                                    first_occurrence=$(date -d "$next_month +${days_to_first} days" "+%Y%m%d" 2>/dev/null)
                                    # Add (N-1) weeks to get Nth occurrence in next month
                                    if [[ -n "$first_occurrence" ]]; then
                                        nth_occurrence=$(date -d "${first_occurrence:0:4}-${first_occurrence:4:2}-${first_occurrence:6:2} +$((occurrence_num - 1)) weeks" "+%Y%m%d" 2>/dev/null)
                                        if [[ -n "$nth_occurrence" ]]; then
                                            current_date="$nth_occurrence"
                                        fi
                                    fi
                                fi
                            else
                                # Fallback: just advance by months
                                current_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +${interval} months" "+%Y%m%d" 2>/dev/null || echo "$current_date")
                            fi
                        else
                            # BYDAY without number or unrecognized format - fallback
                            current_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +${interval} months" "+%Y%m%d" 2>/dev/null || echo "$current_date")
                        fi
                    else
                        # No BYDAY, just advance by months
                        current_date=$(date -d "${current_date:0:4}-${current_date:4:2}-${current_date:6:2} +${interval} months" "+%Y%m%d" 2>/dev/null || echo "$current_date")
                    fi
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
        # Handle empty fields (multiple tabs) by using a more robust parsing approach
        IFS=$'\t' read -r _ dtstart dtend tzid rrule summary <<< "$line"
        # If rrule is empty or looks like a summary, the fields might be shifted
        # Check if rrule doesn't start with FREQ=, then it's likely the summary and fields are shifted
        if [[ -n "$rrule" ]] && [[ ! "$rrule" =~ ^FREQ= ]]; then
            # Fields are shifted: tzid is actually rrule, rrule is actually summary
            # Re-parse more carefully
            IFS=$'\t' read -ra FIELDS <<< "$line"
            if [[ ${#FIELDS[@]} -ge 6 ]]; then
                dtstart="${FIELDS[1]}"
                dtend="${FIELDS[2]}"
                tzid="${FIELDS[3]}"
                rrule="${FIELDS[4]}"
                summary="${FIELDS[5]}"
            elif [[ ${#FIELDS[@]} -eq 5 ]]; then
                # No tzid field (empty)
                dtstart="${FIELDS[1]}"
                dtend="${FIELDS[2]}"
                tzid=""
                rrule="${FIELDS[3]}"
                summary="${FIELDS[4]}"
            fi
        fi
        [[ "$dtend" == "NONE" ]] && dtend=""
        [[ "$tzid" == "NONE" ]] && tzid=""
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
                    # For multi-day events, check if still ongoing (only relevant if it's today)
                    if is_event_ongoing "$current_day" "$dtend_date" "$tzid"; then
                        # For multi-day events, use original start time only on the first day
                        # On subsequent days, use DAY_START_TIME
                        if [[ $current_day == "$local_start" ]]; then
                            # First day - use original start time
                            local_time=$(convert_time "$raw_date" "$tzid")
                            if [[ -n "$local_time" ]]; then
                                echo -e "${current_day}\t${summary}, ${local_time}" >> "$TEMP_EXPANDED"
                            else
                                echo -e "${current_day}\t${summary}" >> "$TEMP_EXPANDED"
                            fi
                        else
                            # Subsequent days - use DAY_START_TIME
                            echo -e "${current_day}\t${summary}, ${DAY_START_TIME}" >> "$TEMP_EXPANDED"
                        fi
                    fi
                    # Move to next day
                    current_day=$(date -d "${current_day:0:4}-${current_day:4:2}-${current_day:6:2} +1 day" "+%Y%m%d" 2>/dev/null || echo "$current_day")
                    # Safety check
                    if [[ ${#current_day} -ne 8 ]]; then
                        break
                    fi
                done
            else
                # Single-day event (or same-day event with start/end times)
                # Check if event is still ongoing (not finished if it's today)
                if is_event_ongoing "$local_start" "$dtend_date" "$tzid"; then
                    # Get the time in local timezone
                    local_time=$(convert_time "$raw_date" "$tzid")
                    if [[ -n "$local_time" ]]; then
                        echo -e "${local_start}\t${summary}, ${local_time}" >> "$TEMP_EXPANDED"
                    else
                        echo -e "${local_start}\t${summary}" >> "$TEMP_EXPANDED"
                    fi
                fi
            fi
        fi
    fi
done < "$TEMP_RAW"

# Sort, deduplicate (only true duplicates), and format
# Sort by date first, then by time (extracted from summary)
# All-day events (no time) will sort first (time = "00:00")
awk -F'\t' '{
    date = $1
    summary = $2
    # Extract time from summary if present (format: "Event, HH:MM")
    time = "00:00"  # Default for all-day events
    # Look for pattern ", HH:MM" or ", H:MM" at the end
    if (match(summary, /, [0-9]{1,2}:[0-9]{2}$/)) {
        # Extract the time part (everything after the last comma and space)
        time_str = substr(summary, RSTART + 2)
        # Parse hour and minute
        split(time_str, time_parts, ":")
        hour = time_parts[1] + 0  # Convert to number to remove leading zeros
        min = time_parts[2]
        # Format as HH:MM with leading zeros
        if (hour < 10) {
            time = "0" hour ":" min
        } else {
            time = hour ":" min
        }
    }
    # Create sort key: date + time (YYYYMMDDHHMM)
    sort_key = date substr(time, 1, 2) substr(time, 4, 2)
    print sort_key "\t" date "\t" summary
}' "$TEMP_EXPANDED" | sort -n | uniq | awk -F'\t' '{
    date = $2
    summary = $3
    month = substr(date, 5, 2) + 0;
    day   = substr(date, 7, 2) + 0;
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ");
    print m[month] " " day "\t" summary;
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
