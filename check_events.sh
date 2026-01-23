#!/bin/bash

# Quick script to check if specific events are in the downloaded .ics files

ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

echo "=== Checking for events in .ics files ==="
echo ""

for URL in $CAL_URLS; do
    [[ -z "$URL" || "$URL" == \#* ]] && continue
    
    echo "Checking: $URL"
    
    # Download and check for events
    curl -s "$URL" | sed 's/\r//' | awk '
    BEGIN {
        in_event = 0
        event_text = ""
        has_dtstart = 0
    }
    /^BEGIN:VEVENT/ {
        in_event = 1
        event_text = ""
        has_dtstart = 0
    }
    /^DTSTART/ {
        has_dtstart = 1
    }
    {
        if (in_event) {
            event_text = event_text "\n" $0
        }
    }
    /^END:VEVENT/ {
        if (has_dtstart) {
            # Extract summary and dates for all events
            summary = ""
            dtstart = ""
            dtend = ""
            rrule = ""
            
            if (match(event_text, /SUMMARY[^:]*:([^\n]+)/, arr)) {
                summary = arr[1]
            }
            if (match(event_text, /DTSTART[^:]*:([0-9TZ]+)/, arr)) {
                dtstart = arr[1]
            }
            if (match(event_text, /DTEND[^:]*:([0-9TZ]+)/, arr)) {
                dtend = arr[1]
            }
            if (match(event_text, /RRULE:([^\n]+)/, arr)) {
                rrule = arr[1]
            }
            
            # Check if this event matches our search terms
            if (summary ~ /Test/i || summary ~ /^Gaelle$/i || summary ~ /Gaelle[^a-z]/i || summary ~ /CLEM.*SOCCER/i || summary ~ /SOCCER.*CLEM/i) {
                print "--- Found matching event ---"
                print "SUMMARY: " summary
                print "DTSTART: " dtstart
                print "DTEND: " dtend
                print "RRULE: " (rrule != "" ? rrule : "none")
                print ""
            }
        }
        in_event = 0
        event_text = ""
        has_dtstart = 0
    }'
    
    echo ""
done

echo "=== Done checking ==="
