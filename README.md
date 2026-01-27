# gcal

Looking for a calendar app on Arch, i came across this link: https://dsl.org/cookbook/cookbook_34.html and went through the rabbit hole!

I'm deeply touched by this extreme simplicity. All you need is a text file and you can get all your incoming events in the terminal. 
Quite naively and with the help of AI, I'm building a bash script (as a quick proof of concept) to integrate this radical simplicity with some contemporary .ics files.
Maybe you get some inspiration from this as well.

As i discovered the beauty of the bsdmainutils' calendar i also discovered how limited it is with today's use. This simple `gcal.sh` utility is made to download 
multiple .ics (iCal) feed; it then removes the past dates, make sure we have the correct date format+tab and turn them into a text file: calendar; which is in turn 
used by the `calendar` command to output either today-tomorrow list, or more.

## Requirements
- `calendar` is part of bsdmainutils; it's available on AUR
- `chmod +x gcal.sh` and `chmod +x gcal-sync`
- `.env` file will provide with an 'array' of urls to download events, one ics per line

## Setup

1. **Create `.env` file** with your calendar URLs:
   ```bash
   CAL_URLS="https://calendar.google.com/calendar/ical/.../basic.ics
   https://another-calendar.com/feed.ics"
   ```

2. **Make scripts executable**:
   ```bash
   chmod +x gcal.sh gcal-sync calendr calendr-notify
   ```

3. **Run initial sync**:
   ```bash
   ./gcal.sh
   ```

4. **Set up automatic syncing** (optional):
   - See "Automatic Calendar Syncing" section below

# Calendr

Custom calendar output script with multiple options:

- `./calendr` - Default: shows today and tomorrow (or Friday+weekend+Monday if Friday, or Saturday+Sunday+Monday if Saturday)
- `./calendr --count` - Display only the number of events
- `./calendr --week` - Display current week (Monday to Sunday)
- `./calendr --nextweek` - Display next week (Monday to Sunday)
- `./calendr --waybar-json` - Output JSON format for waybar with text (count) and tooltip
- `./calendr --help` - Show all available options

# Waybar Integration

## Displaying Calendar in Waybar

Add this to your waybar `config.jsonc`:

```jsonc
{
  "custom/calendar": {
    "format": "📅 {}",
    "exec": "/home/jrgd/tools/calendar/calendr --count",
    "tooltip": true,
    "tooltip-format": "{output}",
    "on-click": "/home/jrgd/tools/calendar/gcal-sync"
  }
}
```

**Note**: Update the path `/home/jrgd/tools/calendar` to match your installation directory.

## Syncing Calendar from Waybar

The `gcal-sync` wrapper script allows you to sync your calendar directly from waybar with minimal visual feedback:

- Shows a brief notification when sync starts ("Syncing...")
- Shows completion notification when done ("Synced ✓")
- Runs in background (non-blocking)
- Automatically handles working directory issues

### Configuration

You can customize the sync behavior via environment variables in your waybar config:

```jsonc
{
  "custom/calendar": {
    "format": "📅 {}",
    "exec": "/home/jrgd/tools/calendar/calendr --count",
    "on-click": "env SHOW_NOTIFICATION=1 /home/jrgd/tools/calendar/gcal-sync"
  }
}
```

**Options**:
- `SHOW_NOTIFICATION=0` - Disable notifications (silent sync)
- `SHOW_NOTIFICATION=1` - Show notifications (default)
- `DEBUG=1` - Enable debug logging to `/tmp/gcal-sync.log`

### Manual Sync

You can also run the sync manually from terminal:

```bash
./gcal-sync
```

Or run the full sync script directly:

```bash
./gcal.sh
```

### Troubleshooting Waybar Integration

- **Calendar not updating on click**: 
  - Make sure `gcal-sync` is executable: `chmod +x gcal-sync`
  - Check that the path in waybar config is correct (use absolute path)
  - Enable debug mode: `env DEBUG=1 /home/jrgd/tools/calendar/gcal-sync` and check `/tmp/gcal-sync.log`
  
- **Notifications not showing**: 
  - Make sure `notify-send` is available (part of `libnotify` package)
  - Verify your notification daemon (mako/dunst) is running

- **Sync runs but calendar file doesn't update**:
  - The wrapper script should handle this automatically by changing to the correct directory
  - If issues persist, check file permissions on the `calendar` file

# Automatic Calendar Syncing

You can set up automatic syncing using either cron or systemd timer.

## Option 1: Systemd User Timer (Recommended)

1. **Create systemd service file** at `~/.config/systemd/user/gcal-sync.service`:
   ```ini
   [Unit]
   Description=Calendar Sync
   After=network.target

   [Service]
   Type=oneshot
   ExecStart=/home/jrgd/tools/calendar/gcal.sh
   WorkingDirectory=/home/jrgd/tools/calendar

   [Install]
   WantedBy=default.target
   ```

2. **Create timer file** at `~/.config/systemd/user/gcal-sync.timer`:
   ```ini
   [Unit]
   Description=Calendar Sync Timer
   Requires=gcal-sync.service

   [Timer]
   OnBootSec=5min
   OnUnitActiveSec=1h

   [Install]
   WantedBy=timers.target
   ```

3. **Enable and start**:
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now gcal-sync.timer
   systemctl --user status gcal-sync.timer
   ```

**Note**: Update paths in the service file to match your installation directory.

## Option 2: Cron

Add to your crontab (`crontab -e`):

```bash
# Sync calendar every hour
0 * * * * /home/jrgd/tools/calendar/gcal.sh > /dev/null 2>&1
```

# Context
https://dsl.org/cookbook/cookbook_34.html
https://news.ycombinator.com/item?id=46726099
repository: https://github.com/jrgd/calendar_tools

# Notes
- Personal interpretation of the ICS rules: an event spanning multiple days will start on its first day at the time of the event; 
  the next day however the event will start as day start (configurable option via `DAY_START_TIME` in `.env`)
- I'm on EST so I had to deviate from UTC, your mileage may vary
- Use `gcal-sync` wrapper when calling from waybar or other GUI applications to ensure proper working directory handling

# Event Notifications

The `calendr-notify` script sends notifications for upcoming calendar events using mako (or any notification daemon compatible with `notify-send`).

## Setup

1. **Install dependencies** (if not already installed):
   ```bash
   # mako (notification daemon for Wayland)
   sudo pacman -S mako libnotify
   ```

2. **Configure notification settings** in `.env`:
   ```bash
   # Notification window in minutes (default: 30)
   NOTIFY_MINUTES=30
   
   # Notification title (default: "📅 Event starting soon")
   NOTIFY_TITLE="📅 Event starting soon"
   ```

3. **Enable and start the systemd user timer**:
   ```bash
   # Reload systemd user daemon
   systemctl --user daemon-reload
   
   # Enable the timer (starts automatically on boot)
   systemctl --user enable calendr-notify.timer
   
   # Start the timer immediately (optional)
   systemctl --user start calendr-notify.timer
   
   # Check status
   systemctl --user status calendr-notify.timer
   ```

4. **Verify it's working**:
   ```bash
   # Check timer status
   systemctl --user list-timers calendr-notify.timer
   
   # Manually trigger a notification check (for testing)
   systemctl --user start calendr-notify.service
   
   # View logs
   journalctl --user -u calendr-notify.service -f
   ```

## How It Works

- The timer runs every 5 minutes
- It checks for events starting within the configured time window (default: 30 minutes)
- Each event gets a unique notification ID to prevent duplicates
- Notifications are tracked in `~/.local/state/calendr/notified/`
- Old notification tracking files are automatically cleaned up (older than 1 day)

## Notification Format

```
📅 Event starting soon
Event Name, HH:MM
Starting in N minutes
```

The title is configurable via `NOTIFY_TITLE` in `.env`.

## Troubleshooting

- **Notifications not appearing**: Make sure mako is running (`mako` or check your hyprland config)
- **Duplicate notifications**: Check `~/.local/state/calendr/notified/` - files older than 1 day are auto-cleaned
- **Timer not running**: Check `systemctl --user status calendr-notify.timer`
- **View logs**: `journalctl --user -u calendr-notify.service -n 50`

# Todo
- create event script (that would update remote calendar as well - tbc)
