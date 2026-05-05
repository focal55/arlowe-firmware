#!/usr/bin/env python3
"""
Voice assistant log viewer and manager.
Logs stored at /var/lib/arlowe/logs/voice/voice_YYYY-MM-DD.log
"""
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

LOG_DIR = Path("/var/lib/arlowe/logs/voice")
KEEP_DAYS = 7

def cleanup_old_logs():
    """Remove logs older than KEEP_DAYS"""
    LOG_DIR.mkdir(exist_ok=True)
    cutoff = datetime.now() - timedelta(days=KEEP_DAYS)
    
    for f in LOG_DIR.glob("voice_*.log"):
        try:
            date_str = f.stem.replace("voice_", "")
            log_date = datetime.strptime(date_str, "%Y-%m-%d")
            if log_date < cutoff:
                f.unlink()
                print(f"Removed old log: {f.name}")
        except:
            pass

def tail_log(lines=20):
    """Show recent log entries"""
    today = datetime.now().strftime("%Y-%m-%d")
    log_file = LOG_DIR / f"voice_{today}.log"
    
    if log_file.exists():
        with open(log_file) as f:
            all_lines = f.readlines()
            for line in all_lines[-lines:]:
                print(line.rstrip())
    else:
        print(f"No log for today: {log_file}")

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "cleanup":
        cleanup_old_logs()
    else:
        tail_log(int(sys.argv[1]) if len(sys.argv) > 1 else 20)
