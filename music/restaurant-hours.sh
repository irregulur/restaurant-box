#!/usr/bin/env bash
# restaurant-hours: exit 0 if the music should be on right now, 1 if not.
# Used by restaurant-audio (start/stop) and restaurant-health (no "not playing" alert at night).
# Uses the box's local time — check it with `timedatectl`.
#
# Closing time includes 20 minutes of grace for customers who are still eating.
#   Mon–Thu  11:00 – 21:20   (close 9pm)
#   Fri–Sat  11:00 – 22:20   (close 10pm)
#   Sun      closed
day=$(date +%u)            # 1 = Monday … 7 = Sunday
now=$((10#$(date +%H%M)))  # e.g. 1105; 10# so 0930 is not read as octal

case "$day" in
    [1-4]) open=1100 close=2120 ;;   # Mon–Thu
    [56])  open=1100 close=2220 ;;   # Fri, Sat
    *)     exit 1 ;;                 # Sunday: closed, no music
esac

[ "$now" -ge "$open" ] && [ "$now" -lt "$close" ]
