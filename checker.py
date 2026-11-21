import asyncio
import time
import json
import os
import requests
from playwright.async_api import async_playwright
from dotenv import load_dotenv

load_dotenv()

# ── Config — reads from .env file or environment variables ───────────────────
USERNAME        = os.environ["UNISA_USERNAME"]
PASSWORD        = os.environ["UNISA_PASSWORD"]
STUDENT_NUMBER  = os.environ["STUDENT_NUMBER"]
CHECK_INTERVAL  = int(os.environ.get("CHECK_INTERVAL", "300"))

TELEGRAM_BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
TELEGRAM_CHAT_ID   = os.environ["TELEGRAM_CHAT_ID"]

LOGIN_URL   = "https://cas.unisa.ac.za/cas/login?service=https%3a%2f%2fmyadmin.unisa.ac.za%2fstudent%2fportal%2fexam-results-app%2f"
SEARCH_URL  = "https://myadmin.unisa.ac.za/student/portal/exam-results-app/search"
STATE_FILE  = os.path.join(os.environ.get("STATE_DIR", os.path.dirname(os.path.abspath(__file__))), "results_state.json")

# Fallback values used only if the page dropdowns can't be read
ACADEMIC_YEAR_FALLBACK   = os.environ.get("ACADEMIC_YEAR",   "2026")
ACADEMIC_PERIOD_FALLBACK = os.environ.get("ACADEMIC_PERIOD", "10")

LOGIN_RETRIES    = 10    # max attempts per login call
LOGIN_RETRY_WAIT = 5   # seconds between login attempts
# ─────────────────────────────────────────────────────────────────────────────


def load_state(year, period):
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE, "r") as f:
            data = json.load(f)
        return data.get(str(year), {}).get(str(period), {})
    return {}


def save_state(year, period, marks):
    data = {}
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE, "r") as f:
            data = json.load(f)
    data.setdefault(str(year), {})[str(period)] = marks
    with open(STATE_FILE, "w") as f:
        json.dump(data, f, indent=2)
    print(f"  State saved to {STATE_FILE} [{year}/{period}]")


async def _do_login(page):
    """Single login attempt. Returns cookie string on success, raises on failure."""
    print("  Navigating to login page...")
    await page.goto(LOGIN_URL)
    await page.wait_for_timeout(5000)
    print(f"  Current URL: {page.url}")

    # Already landed on myadmin — session still valid
    if "myadmin.unisa.ac.za" in page.url and "cas.unisa.ac.za" not in page.url:
        print("  Already logged in — reusing session.")
        raw_cookies = await page.context.cookies()
        return "; ".join([f"{c['name']}={c['value']}" for c in raw_cookies])

    await page.fill('#username', USERNAME)
    await page.fill('#password', PASSWORD)

    print("  Submitting...")
    await page.click('input[type="submit"], button[type="submit"]')
    await page.wait_for_url("**/myadmin.unisa.ac.za/**", timeout=60000)

    print(f"  Logged in! URL: {page.url}")
    raw_cookies = await page.context.cookies()
    return "; ".join([f"{c['name']}={c['value']}" for c in raw_cookies])


async def re_login(page):
    """Login with retries and exponential-ish backoff. Never gives up permanently."""
    attempt = 0
    while True:
        attempt += 1
        try:
            return await _do_login(page)
        except Exception as e:
            wait = LOGIN_RETRY_WAIT * attempt
            if attempt < LOGIN_RETRIES:
                print(f"  [{time.strftime('%H:%M:%S')}] Login attempt {attempt} failed: {e}")
                print(f"  Retrying in {wait}s...")
                await asyncio.sleep(wait)
            else:
                # Exhausted fast retries — keep trying every 5 minutes indefinitely
                print(f"  [{time.strftime('%H:%M:%S')}] Login attempt {attempt} failed: {e}")
                print(f"  Will retry in 5 minutes...")
                await asyncio.sleep(300)
                attempt = 0  # reset counter so backoff starts fresh next round


async def get_auth(playwright):
    """Launch browser and log in, then scrape the current year/period from the search page."""
    print("  Launching internal browser...")
    browser = await playwright.chromium.launch(headless=True)
    context = await browser.new_context()
    page    = await context.new_page()
    cookies = await re_login(page)
    year, period = await scrape_period(page)
    return cookies, page, year, period


async def scrape_period(page):
    """
    Navigate to the search page and read the currently selected year and period
    from the dropdowns. Falls back to env/default values if scraping fails.
    """
    try:
        print("  Reading current academic period from search page...")
        await page.goto(SEARCH_URL)
        await page.wait_for_load_state("networkidle", timeout=20000)

        # Strip Angular's "index: value" formatting (e.g. "3: 10" -> "10")
        def strip_ng(val):
            if val and ': ' in val:
                return val.split(': ', 1)[1].strip()
            return val

        year = await page.evaluate("""() => {
            const el = document.querySelector('input#examYear');
            return el ? el.value : null;
        }""")

        period = strip_ng(await page.evaluate("""() => {
            const el = document.querySelector('select#examinationperiod');
            return el ? el.value : null;
        }"""))

        if year and period:
            print(f"  Detected period: year={year}, period={period}")
            return year, period

        print(f"  Could not detect period from page (year={year}, period={period}) — using fallback values")

    except Exception as e:
        print(f"  Period scrape failed: {e} — using fallback values")

    print(f"  Fallback: year={ACADEMIC_YEAR_FALLBACK}, period={ACADEMIC_PERIOD_FALLBACK}")
    return ACADEMIC_YEAR_FALLBACK, ACADEMIC_PERIOD_FALLBACK


def check_results(cookies, year, period):
    url = (
        f"https://myadmin.unisa.ac.za/myadmin-exam-services/services/rest/"
        f"examresultservice/examresults?academicYear={year}&academicPeriod={period}"
        f"&studentNumber={STUDENT_NUMBER}&toolName=exam-results-app"
    )
    headers = {
        "Accept":         "application/json, text/plain, */*",
        "Cookie":         cookies,
        "Referer":        "https://myadmin.unisa.ac.za/student/portal/exam-results-app/search",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
    }
    r = requests.get(url, headers=headers, timeout=15)
    if r.status_code in (401, 403):
        print(f"  API returned {r.status_code}")
        return None, True
    r.raise_for_status()
    print(f"  Status: {r.status_code} | Response: {r.text[:300]}")
    if r.text.strip().startswith("<"):
        print("  Got HTML response instead of JSON — session invalid.")
        return None, True
    return r.json(), False


def send_telegram(message):
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    r   = requests.post(url, json={"chat_id": TELEGRAM_CHAT_ID, "text": message}, timeout=10)
    r.raise_for_status()


def notify(new_results):
    lines   = [f"{course}: {mark}%" for course, mark in new_results.items()]
    message = (
        f"📋 New UNISA Results published!\n\n"
        f"{chr(10).join(lines)}\n\n"
        f"Check now: https://myadmin.unisa.ac.za/student/portal/exam-results-app/search"
    )
    try:
        send_telegram(message)
        print("  Telegram sent")
    except Exception as e:
        print(f"  Telegram failed: {e}")


async def main():
    async with async_playwright() as playwright:
        print("=== UNISA Results Checker ===\n")

        cookies, page, year, period = await get_auth(playwright)
        print("Login successful.\n")
        print(f"  Academic year: {year} | period: {period}\n")

        previous = load_state(year, period)
        print(f"  Loaded previous state [{year}/{period}]: {previous}\n")

        consecutive_errors = 0

        while True:
            try:
                data, needs_reauth = check_results(cookies, year, period)

                if needs_reauth:
                    print(f"[{time.strftime('%H:%M:%S')}] Session expired — re-logging in...")
                    cookies = await re_login(page)
                    new_year, new_period = await scrape_period(page)
                    if (new_year, new_period) != (year, period):
                        print(f"  Period changed: {year}/{period} → {new_year}/{new_period}")
                        year, period = new_year, new_period
                        previous = load_state(year, period)
                        print(f"  Loaded state [{year}/{period}]: {previous}")
                    else:
                        year, period = new_year, new_period
                    consecutive_errors = 0
                    continue

                courses = data.get("courseResult", []) if isinstance(data, dict) else []
                current = {c["course"]: c["finalMark"] for c in courses}
                print(f"[{time.strftime('%H:%M:%S')}] Marks: {current}")

                new_results = {
                    course: mark
                    for course, mark in current.items()
                    if mark != "***" and previous.get(course, "***") == "***"
                }

                if new_results:
                    print(f">>> NEW RESULTS: {new_results}")
                    notify(new_results)
                    previous.update(new_results)
                    save_state(year, period, previous)

                consecutive_errors = 0

            except Exception as e:
                consecutive_errors += 1
                print(f"[{time.strftime('%H:%M:%S')}] Error ({consecutive_errors}): {e}")
                if consecutive_errors >= 3:
                    print("3 consecutive errors — re-logging in...")
                    cookies = await re_login(page)
                    new_year, new_period = await scrape_period(page)
                    if (new_year, new_period) != (year, period):
                        print(f"  Period changed: {year}/{period} → {new_year}/{new_period}")
                        year, period = new_year, new_period
                        previous = load_state(year, period)
                    else:
                        year, period = new_year, new_period
                    consecutive_errors = 0

            await asyncio.sleep(CHECK_INTERVAL)


asyncio.run(main())
