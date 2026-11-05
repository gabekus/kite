# Writes the hand-made Chromium "History" databases the Import from Arc tests read
# (tests/ArcHistoryImportTests.cpp, KitecoreCliTest.cmake). Every URL, title and time is invented.
#
#   py -I windows/scripts/make-history.py
#   py -I windows/scripts/make-history.py --synthetic OUT.sqlite [MEGABYTES]
#
# The fixture Arc folder gets "User Data/Default/History" and "User Data/Profile 1/History",
# with the urls and visits tables as Chromium's History version 70 has them (the schema Arc for
# Windows writes). Default's urls has every kind of row the import reads or leaves out: pages,
# a hidden one, one never visited, ones that aren't web pages, a NULL title, a title with a NUL
# in it and one that isn't UTF-8 (a BLOB), a URL long enough to spill onto overflow pages, and
# enough pages on 1 KiB pages for the table's b-tree to have interior pages.
#
# --synthetic writes a big History of the same shape (default 200 MB, 4 KiB pages as Chromium's)
# for measuring the import: about 360,000 pages and 3 visits each.

import os
import sqlite3
import sys

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "fixtures")
ARC = os.path.join(HERE, "arc-windows", "Packages", "TheBrowserCompany.Arc_kitetest0001", "LocalCache", "Local", "Arc")

URLS = (
    "CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT,url LONGVARCHAR,title LONGVARCHAR,"
    "visit_count INTEGER DEFAULT 0 NOT NULL,typed_count INTEGER DEFAULT 0 NOT NULL,"
    "last_visit_time INTEGER NOT NULL,hidden INTEGER DEFAULT 0 NOT NULL)"
)
VISITS = (
    "CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT,url INTEGER NOT NULL,visit_time INTEGER NOT NULL,"
    "from_visit INTEGER,external_referrer_url TEXT,transition INTEGER DEFAULT 0 NOT NULL,segment_id INTEGER,"
    "visit_duration INTEGER DEFAULT 0 NOT NULL,incremented_omnibox_typed_score BOOLEAN DEFAULT FALSE NOT NULL,"
    "opener_visit INTEGER,originator_cache_guid TEXT,originator_visit_id INTEGER,originator_from_visit INTEGER,"
    "originator_opener_visit INTEGER,is_known_to_sync BOOLEAN DEFAULT FALSE NOT NULL,"
    "consider_for_ntp_most_visited BOOLEAN DEFAULT FALSE NOT NULL,visited_link_id INTEGER DEFAULT 0 NOT NULL,app_id TEXT)"
)

# 2026-10-01 00:00:00 UTC in Chromium's microseconds since 1601-01-01.
BASE = (1790812800 + 11644473600) * 1_000_000
SECOND = 1_000_000


def create(path, page_size):
    for suffix in ("", "-journal", "-wal", "-shm"):
        if os.path.exists(path + suffix):
            os.remove(path + suffix)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    db = sqlite3.connect(path)
    db.execute(f"PRAGMA page_size={page_size}")
    db.execute("CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)")
    db.execute("INSERT INTO meta VALUES ('version', '70')")
    db.execute(URLS)
    db.execute("CREATE INDEX urls_url_index ON urls (url)")
    db.execute(VISITS)
    db.execute("CREATE INDEX visits_url_index ON visits (url)")
    db.execute("CREATE INDEX visits_time_index ON visits (visit_time)")
    return db


def add(db, url, title, visits, last, hidden=0):
    cursor = db.execute(
        "INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES (?, ?, ?, ?, ?)", (url, title, visits, last, hidden)
    )
    if not db.execute("SELECT 1 FROM sqlite_master WHERE name = 'visits'").fetchone():
        return
    for n in range(max(visits, 1) if last else 0):
        db.execute("INSERT INTO visits (url, visit_time, transition) VALUES (?, ?, 805306368)", (cursor.lastrowid, last - n * 60 * SECOND))


def fixture():
    db = create(os.path.join(ARC, "User Data", "Default", "History"), 1024)
    # Enough pages for interior pages: page1 ... page80, an hour apart, oldest first.
    for n in range(1, 81):
        add(db, f"https://page{n}.example.test/", f"Page {n}", n % 4, BASE + n * 3600 * SECOND)
    add(db, "https://docs.kite.example/start", "Kite Docs", 3, BASE + 500 * 3600 * SECOND)
    add(db, "https://news.example.test/", "News", 0, BASE + 400 * 3600 * SECOND)  # a count of 0 is 1
    add(db, "https://hidden.example.test/frame", "Frame", 1, BASE + 450 * 3600 * SECOND, hidden=1)
    add(db, "https://never.example.test/", "Never", 0, 0)
    add(db, "chrome://settings/", "Settings", 2, BASE + 460 * 3600 * SECOND)
    add(db, "file:///C:/notes.txt", "notes.txt", 1, BASE + 300 * 3600 * SECOND)
    add(db, "https://long.example.test/?pad=" + "x" * 3000, "Long", 1, BASE + 350 * 3600 * SECOND)
    add(db, "https://untitled.example.test/", None, 1, BASE + 200 * 3600 * SECOND)
    add(db, "https://nul.example.test/", "Before\0After", 1, BASE + 150 * 3600 * SECOND)
    add(db, "https://latin1.example.test/", b"Caf\xe9", 1, BASE + 120 * 3600 * SECOND)
    db.commit()
    db.close()

    db = create(os.path.join(ARC, "User Data", "Profile 1", "History"), 1024)
    add(db, "https://side.example.test/", "Side Project", 2, BASE + 100 * 3600 * SECOND)
    add(db, "https://docs.kite.example/start", "Kite Docs", 1, BASE + 600 * 3600 * SECOND)
    db.commit()
    db.close()

    # tests/fixtures/history-raw-urls.sqlite: URLs as Chromium keeps them, with characters NSURL
    # percent-encodes left as typed, and the same page already encoded (an older visit).
    db = create(os.path.join(HERE, "history-raw-urls.sqlite"), 1024)
    add(db, "https://pipes.example.test/a|b?q={x}", "Raw", 2, BASE + 20 * 3600 * SECOND)
    add(db, "https://pipes.example.test/a%7Cb?q=%7Bx%7D", "Encoded", 5, BASE + 10 * 3600 * SECOND)
    add(db, "https://braces.example.test/{id}#a|b", "Fragment", 1, BASE + 5 * 3600 * SECOND)
    # A path with an escape already in it that also needs encoding: NSURL encodes the part whole.
    add(db, "https://pct.example.test/a%20b|c", "Escaped", 1, BASE + 2 * 3600 * SECOND)
    # The same page twice once encoded, the newer row with no title: the older one's title stays.
    add(db, "https://notitle.example.test/x|y", None, 1, BASE + 3 * 3600 * SECOND)
    add(db, "https://notitle.example.test/x%7Cy", "Older", 4, BASE + 1 * 3600 * SECOND)
    db.commit()
    db.close()

    # tests/fixtures/history-big-schema.sqlite: a schema row past the reader's 64 KB cap (a
    # 70 KB DEFAULT, on overflow pages) before the urls table.
    path = os.path.join(HERE, "history-big-schema.sqlite")
    for suffix in ("", "-journal"):
        if os.path.exists(path + suffix):
            os.remove(path + suffix)
    db = sqlite3.connect(path)
    db.execute("PRAGMA page_size=1024")
    db.execute("CREATE TABLE pad(x TEXT DEFAULT '" + "p" * 70_000 + "')")
    db.execute(URLS)
    add(db, "https://after.example.test/", "After", 1, BASE)
    db.commit()
    db.close()


def synthetic(path, megabytes):
    db = create(path, 4096)
    target = megabytes * 1_000_000
    n = 0
    while True:
        rows = []
        for _ in range(20_000):
            n += 1
            host = f"site{n % 5000}.example.test"
            rows.append((f"https://{host}/articles/{n:08d}/a-made-up-page-with-a-long-slug-{n * 7919 % 100000}?ref=feed&utm=x{n % 97}",
                         f"A made-up page {n} on {host}, with a title of a usual length", 3, BASE + n * SECOND, 1 if n % 50 == 0 else 0))
        db.executemany("INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES (?, ?, ?, ?, ?)", rows)
        db.executemany("INSERT INTO visits (url, visit_time, transition) VALUES (?, ?, 805306368)",
                       [(n - 20_000 + i + 1, BASE + (n - 20_000 + i + 1) * SECOND - k * SECOND) for i in range(20_000) for k in range(3)])
        db.commit()
        if os.path.getsize(path) >= target:
            break
    db.close()
    print(f"{path}: {os.path.getsize(path) / 1e6:.0f} MB, {n} pages")


if len(sys.argv) >= 3 and sys.argv[1] == "--synthetic":
    synthetic(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 200)
else:
    fixture()
