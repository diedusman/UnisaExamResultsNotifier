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
   git clone https://github.com/YOUR_USERNAME/UNISA_Results_Checker.git
   cd UNISA_Results_Checker
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
   ACADEMIC_YEAR=2026
   ACADEMIC_PERIOD=10
   CHECK_INTERVAL=300
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
   git clone https://github.com/YOUR_USERNAME/UNISA_Results_Checker.git
   cd UNISA_Results_Checker
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

## Option 3: LXC Container (Linux hosts — Proxmox, Ubuntu, Debian)

Deploys the checker inside a lightweight LXC container that runs as a `systemd` service, starting automatically on boot.

### Prerequisites
- A Linux host (bare metal or VM) running Ubuntu or Debian
- `lxc-utils` installed:
  ```bash
  sudo apt install lxc lxc-utils
  ```

### Steps

1. Clone the repo on your Linux host:
   ```bash
   git clone https://github.com/diedusman/UnisaExamResultsNotifier.git
   cd UNISA_Results_Checker
   ```

2. Edit `deploy_lxc.sh` and set your GitHub repo URL at the top:
   ```bash
   GITHUB_REPO="https://github.com/diedusman/UnisaExamResultsNotifier.git"
   ```

3. Make it executable and run it:
   ```bash
   chmod +x deploy_lxc.sh
   sudo ./deploy_lxc.sh
   ```

4. The script will prompt you for your credentials, create the container, install everything, and start the service automatically.

### Useful commands after deployment
```bash
# View live logs
lxc-attach -n unisa-checker -- journalctl -fu unisa-checker

# Restart the checker
lxc-attach -n unisa-checker -- systemctl restart unisa-checker

# Open a shell inside the container
lxc-attach -n unisa-checker

# Destroy the container completely
lxc-stop -n unisa-checker && lxc-destroy -n unisa-checker
```

---

## How it works

- Logs in to UNISA via the CAS login page using Playwright (a headless browser)
- Calls the exam results API every 5 minutes
- Saves the last known marks to `results_state.json`
- Only notifies you when a subject changes from `***` (outstanding) to an actual mark
- Re-authenticates automatically when the session expires

## Notes

- Change `ACADEMIC_YEAR` and `ACADEMIC_PERIOD` in `.env` for future semesters
- The checker runs indefinitely — stop it manually once all your results are out
- Never share your `.env` file or commit it to git — it is listed in `.gitignore`
