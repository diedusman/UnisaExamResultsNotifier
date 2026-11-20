# UNISA Results Checker

Polls the UNISA results API every 5 minutes and sends a Telegram notification the moment a new result is published. Supports three deployment options.

---

## Setup — Telegram Bot (everyone needs this)

1. Message [@BotFather](https://t.me/botfather) on Telegram and create a bot. Copy the token it gives you.
2. Send any message to your new bot.
3. Open this URL in your browser (replace `YOUR_TOKEN`):
   ```
   https://api.telegram.org/botYOUR_TOKEN/getUpdates
   ```
4. Find `"id"` inside `"chat"` — that is your chat ID.

---

## Option 1: Docker (recommended — no Python needed)

### Prerequisites
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)

### Steps

1. Clone the repo:
   ```bash
   git clone https://github.com/diedusman/UnisaExamResultsNotifier.git
   cd UnisaExamResultsNotifier
   ```

2. Copy `.env.example` to `.env` and fill in your details:
   ```bash
   cp .env.example .env
   ```
   ```
   UNISA_USERNAME=your_student_number
   UNISA_PASSWORD=your_password
   STUDENT_NUMBER=your_student_number
   TELEGRAM_BOT_TOKEN=your_bot_token
   TELEGRAM_CHAT_ID=your_chat_id
   CHECK_INTERVAL=300
   ```

   `ACADEMIC_YEAR` and `ACADEMIC_PERIOD` are optional — the checker reads them automatically from the UNISA results page. Set them only as a fallback if auto-detection fails:
   ```
   ACADEMIC_YEAR=2026
   ACADEMIC_PERIOD=10
   ```

3. Build and run:
   ```bash
   docker compose up -d
   ```

4. View logs:
   ```bash
   docker compose logs -f
   ```

5. Stop:
   ```bash
   docker compose down
   ```

The checker runs in the background and restarts automatically if it crashes. Results state is saved in `./data/` and survives restarts.

---

## Option 2: Plain Python

### Prerequisites
- Python 3.10 or newer — [python.org/downloads](https://www.python.org/downloads/)

### Steps

1. Clone the repo:
   ```bash
   git clone https://github.com/diedusman/UnisaExamResultsNotifier.git
   cd UnisaExamResultsNotifier
   ```

2. Install dependencies:
   ```bash
   pip install -r requirements.txt
   playwright install chromium
   ```

3. Copy `.env.example` to `.env` and fill in your details:
   ```bash
   cp .env.example .env
   ```

4. Run:
   ```bash
   python checker.py
   ```

To keep it running after closing your terminal:
```bash
# Windows
start /B pythonw checker.py

# Mac/Linux
nohup python checker.py &
```

---

## Option 3: LXC Container (Proxmox VE)

Deploys the checker as a proper Proxmox LXC container — visible in the web UI with CPU/RAM graphs, starts automatically on boot, and managed with `pct` like any other container.

### Prerequisites
- Proxmox VE host (no git or extra packages needed)

### Steps

1. In the Proxmox shell, run:
   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/diedusman/UnisaExamResultsNotifier/main/deploy_lxc.sh)"
   ```

2. The script will prompt you for:
   - **VMID** — auto-suggests the next free ID
   - **Network bridge** — lists available bridges (typically `vmbr0`)
   - **IP** — DHCP or static (with gateway and DNS if static)
   - **Storage** — lists available storages for template and rootfs
   - **RAM, disk, CPUs**
   - **UNISA credentials and Telegram details**

3. It then downloads the Ubuntu 24.04 template if needed, creates the container, installs everything, and starts the service automatically.

### Useful commands after deployment
```bash
# View live logs (replace 200 with your VMID)
pct exec 200 -- journalctl -fu unisa-checker

# Restart the checker
pct exec 200 -- systemctl restart unisa-checker

# Open a shell inside the container
pct enter 200

# Stop the container
pct stop 200

# Destroy the container completely
pct stop 200 && pct destroy 200
```

---

## How it works

- Logs in to UNISA via the CAS login page using Playwright (a headless browser)
- Calls the exam results API every 5 minutes
- Saves the last known marks to `results_state.json`
- Only notifies you when a subject changes from `***` (outstanding) to an actual mark
- Re-authenticates automatically when the session expires

## Notes

- `ACADEMIC_YEAR` and `ACADEMIC_PERIOD` are read automatically from the UNISA results page on each login — no need to update them each semester
- Set them in `.env` only as a fallback if auto-detection fails
- The checker runs indefinitely — stop it manually once all your results are out
- Never share your `.env` file or commit it to git — it is listed in `.gitignore`
