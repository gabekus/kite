# Writes the hand-made Chromium "Web Data" databases the Import from Arc tests read
# (tests/ArcImportFilesTests.cpp, KitecoreCliTest.cmake). Every value is invented.
#
#   py -I windows/tests/fixtures/make-web-data.py
#
# web-data.sqlite (in the fixture Arc folder) has Chromium's keywords table written the way an
# old profile has it: rows from before `is_active` was added (ALTER TABLE ... ADD COLUMN, so
# they're shorter records), rows after, a long one that spills onto overflow pages, and enough
# prepopulated engines on 1 KiB pages for the table's b-tree to have interior pages.
# legacy-web-data.sqlite is from before Chromium had `is_active` at all.

import os
import sqlite3

HERE = os.path.dirname(os.path.abspath(__file__))
ARC = os.path.join(HERE, "arc-windows", "Packages", "TheBrowserCompany.Arc_kitetest0001", "LocalCache", "Local", "Arc")

OLD_COLUMNS = (
    "id INTEGER PRIMARY KEY,short_name VARCHAR NOT NULL,keyword VARCHAR NOT NULL,favicon_url VARCHAR NOT NULL,"
    "url VARCHAR NOT NULL,safe_for_autoreplace INTEGER,originating_url VARCHAR,date_created INTEGER DEFAULT 0,"
    "usage_count INTEGER DEFAULT 0,input_encodings VARCHAR,suggest_url VARCHAR,prepopulate_id INTEGER DEFAULT 0,"
    "created_by_policy INTEGER DEFAULT 0,last_modified INTEGER DEFAULT 0,sync_guid VARCHAR"
)


def make(path, alter):
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.execute("PRAGMA page_size=1024")
    db.execute("CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)")
    db.execute("INSERT INTO meta VALUES ('version', '130')")
    db.execute(f"CREATE TABLE keywords ({OLD_COLUMNS})")
    db.execute("CREATE TABLE autofill (name VARCHAR, value VARCHAR, value_lower VARCHAR, date_created INTEGER DEFAULT 0)")
    db.execute("CREATE INDEX autofill_name ON autofill (name)")

    def add(name, keyword, url, safe, created, prepopulate=0, **extra):
        columns = ["short_name", "keyword", "favicon_url", "url", "safe_for_autoreplace", "date_created", "prepopulate_id"]
        values = [name, keyword, "", url, safe, created, prepopulate]
        for key, value in extra.items():
            columns.append(key)
            values.append(value)
        db.execute(f"INSERT INTO keywords ({','.join(columns)}) VALUES ({','.join('?' * len(values))})", values)

    # Chromium's own engines: never imported, and enough of them for interior pages.
    for n in range(1, 61):
        add(f"Engine {n}", f"engine{n}.example.test", f"https://engine{n}.example.test/search?q={{searchTerms}}", 1, 10 + n, prepopulate=n)

    add("Kite Docs", "kd", "https://docs.kite.example/search?q={searchTerms}", 0, 300)
    add("Visited Site", "visited.example.test", "https://visited.example.test/?q={searchTerms}", 1, 100)
    if alter:
        for column in ("is_active INTEGER DEFAULT 0", "starter_pack_id INTEGER DEFAULT 0", "enforced_by_policy INTEGER DEFAULT 0"):
            db.execute(f"ALTER TABLE keywords ADD COLUMN {column}")
        add("Turned On", "on.example.test", "https://on.example.test/?s={searchTerms}", 1, 200, is_active=1)
        add("Turned Off", "off", "https://off.example.test/find/{searchTerms}", 0, 400, is_active=2)
        add("Needs Chromium", "nc", "{google:baseURL}search?q={searchTerms}", 0, 50, is_active=1)
        add("Starter", "@tabs", "chrome://tabs/?q={searchTerms}", 0, 60, is_active=1, starter_pack_id=2)
        add("Long One", "long", "https://long.example.test/search?q={searchTerms}&pad=" + "x" * 3000, 0, 500, is_active=1)
        add("Same Day", "same", "https://same.example.test/?q={searchTerms}", 0, 300, is_active=1)
        add("No Date", "nd", "https://nd.example.test/?q={searchTerms}", 0, None, is_active=1)
        add("Auto Added", "auto.example.test", "https://auto.example.test/?q={searchTerms}", 1, 250, is_active=0)
    else:
        add("Mine Too", "mt", "https://mine.example.test/?q={searchTerms}", 0, 200)
    db.commit()
    db.close()


make(os.path.join(ARC, "User Data", "Default", "Web Data"), alter=True)
make(os.path.join(HERE, "legacy-web-data.sqlite"), alter=False)
