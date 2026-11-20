"""Read-only check of every Jellyfin request JellySpace makes, against a real server.

Each request is sent the way the app sends it (same paths and query items) and its answer is
checked for the fields the app's Swift decoders require (a missing required field fails the
decode, and the page would show an error). Nothing is changed on the server: only GETs (and
ranged GETs for streams) are sent.

Usage: python ios/tools/jellyspace_api_check.py [server]   (default http://localhost:8096)
The API key is read from .local/jellyfin-test.key (git-ignored) or JELLYFIN_KEY.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8096").rstrip("/")
KEY = os.environ.get("JELLYFIN_KEY") or open(os.path.join(os.path.dirname(__file__), "..", "..", ".local", "jellyfin-test.key")).read().strip()
AUTH = f'MediaBrowser Client="TwilDiary", Device="iPhone", DeviceId="twildiary-ios", Version="2.0", Token="{KEY}"'

passed, failed, notes = 0, 0, []


def url(path, query=None):
    q = urllib.parse.urlencode(query or {}, safe=",")
    return f"{BASE}/{path}" + (f"?{q}" if q else "")


def shown(u):
    return u.replace(KEY, "<key>")


def get(path, query=None, raw=False, headers=None):
    request = urllib.request.Request(url(path, query), headers={"Authorization": AUTH, "Accept": "application/json", **(headers or {})})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
        return (response.status, response.headers.get("Content-Type", ""), body) if raw else json.loads(body or b"null")


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"  PASS  {name}" + (f"  ({detail})" if detail else ""))
    else:
        failed += 1
        print(f"  FAIL  {name}" + (f"  ({detail})" if detail else ""))


def need(obj, fields, where):
    """The decoder's non-optional fields, present and of the right type."""
    missing = [f for f, kind in fields.items() if f not in obj or obj[f] is None or not isinstance(obj[f], kind)]
    return not missing, (f"{where}: missing {missing}" if missing else "")


def page(name, path, query, item_check=True):
    try:
        data = get(path, query)
    except urllib.error.HTTPError as e:
        check(name, False, f"HTTP {e.code} {shown(url(path, query))}")
        return []
    ok, why = need(data, {"Items": list, "TotalRecordCount": int}, "page")
    if ok and item_check:
        for item in data["Items"]:
            ok, why = need(item, {"Id": str, "Type": str}, f"item {item.get('Name')}")
            if not ok:
                break
    check(name, ok, why or f"{len(data.get('Items', []))} of {data.get('TotalRecordCount')}")
    return data.get("Items", []) if isinstance(data, dict) else []


def items_array(name, path, query):
    try:
        data = get(path, query)
    except urllib.error.HTTPError as e:
        check(name, False, f"HTTP {e.code}")
        return []
    ok = isinstance(data, list) and all(isinstance(i.get("Id"), str) and isinstance(i.get("Type"), str) for i in data)
    check(name, ok, f"{len(data) if isinstance(data, list) else 'not a list'} items")
    return data if isinstance(data, list) else []


def fetch(name, path, query=None, expect="image", ranged=False):
    try:
        status, kind, body = get(path, query, raw=True, headers={"Range": "bytes=0-1023"} if ranged else None)
        check(name, status in (200, 206) and (expect in kind or expect == "any"), f"HTTP {status} {kind} {len(body)} bytes")
    except urllib.error.HTTPError as e:
        check(name, False, f"HTTP {e.code} {shown(url(path, query))}")


print(f"Server {BASE}")
info = get("System/Info/Public")
print(f"  {info.get('ServerName')} {info.get('Version')}\n")

print("Users and libraries")
users = get("Users")
ok = isinstance(users, list) and all(isinstance(u.get("Id"), str) for u in users)
check("Users (profiles, JellyfinUser.id)", ok, f"{len(users)} users")
admin = next((u for u in users if (u.get("Policy") or {}).get("IsAdministrator")), users[0])
user = admin["Id"]
folders = get("Library/VirtualFolders")
check("Library/VirtualFolders (libraries)", all(isinstance(f.get("Name"), str) for f in folders), f"{len(folders)} libraries")
# Only these libraries are read (the owner's choice: Shows and Movies); every request below is kept
# inside them.
ONLY = {name.strip() for name in os.environ.get("JELLYSPACE_LIBRARIES", "Shows,Movies").split(",")}
libraries = [(f.get("ItemId"), f["Name"], (f.get("CollectionType") or "").lower()) for f in folders if f.get("ItemId") and f["Name"] in ONLY]
print(f"  testing only: {', '.join(n for _, n, _ in libraries)}")

print("\nHome")
latest = {}
for lib_id, name, kind in libraries:
    page(f"Continue Watching in {name}", "UserItems/Resume", {"userId": user, "MediaTypes": "Video", "Fields": "ProviderIds", "Limit": 20, "ParentId": lib_id})
    page(f"Favourites in {name}", "Items", {"Recursive": "true", "Fields": "ProviderIds,Path,Overview", "Limit": 20, "SortBy": "DateCreated,SortName",
                                            "SortOrder": "Descending", "IncludeItemTypes": "Movie,Series,Episode", "Filters": "IsFavorite", "userId": user, "ParentId": lib_id})
    latest[lib_id] = items_array(f"Latest in {name}", "Items/Latest", {"parentId": lib_id, "userId": user, "Limit": 16, "Fields": "ProviderIds"})
    fetch(f"{name} library picture (My Media)", f"Items/{lib_id}/Images/Primary", {"maxWidth": 600, "quality": 90}, expect="any")
heroes = [i for items in latest.values() for i in items if i["Type"] in ("Movie", "Series") and i.get("BackdropImageTags")]
check("Top poster has titles with backdrops", len(heroes) > 0, f"{len(heroes)} candidates")
logos = [i for i in heroes if (i.get("ImageTags") or {}).get("Logo")]
notes.append(f"{len(logos)} of {len(heroes)} top-poster titles have a logo")

print("\nFolders")
for lib_id, name, kind in libraries:
    rows = page(f"{name}: first page, folders first", "Items", {"ParentId": lib_id, "Recursive": "false", "Fields": "ProviderIds,Path,Overview",
                                                                "StartIndex": 0, "Limit": 200, "SortBy": "IsFolder,SortName", "SortOrder": "Descending,Ascending", "userId": user})
    flags = [bool(r.get("IsFolder")) for r in rows]
    check(f"{name}: folders come before files", flags == sorted(flags, reverse=True), f"{sum(flags)} folders, {len(flags) - sum(flags)} files")
    page(f"{name}: unwatched filter", "Items", {"ParentId": lib_id, "Recursive": "false", "StartIndex": 0, "Limit": 5, "Filters": "IsUnplayed", "userId": user})

print("\nSearch")
for lib_id, name, kind in libraries:
    page(f"Search in {name}", "Items", {"Recursive": "true", "IncludeItemTypes": "Movie,Series,Episode", "Fields": "ProviderIds", "Limit": 60,
                                        "SearchTerm": "the", "ParentId": lib_id})

print("\nA show")
series = next((i for items in latest.values() for i in items if i["Type"] == "Series"), None)
if not series:
    shows = page("Any show", "Items", {"Recursive": "true", "IncludeItemTypes": "Series", "Limit": 1, "userId": user, "ParentId": libraries[0][0]})
    series = shows[0] if shows else None
if series:
    sid = series["Id"]
    print(f"  ({series.get('Name')})")
    detail = get(f"Items/{sid}", {"userId": user})
    ok, why = need(detail, {"Id": str, "Type": str}, "detail")
    check("Show page (Items/{id})", ok, why or f"genres {len(detail.get('GenreItems') or [])}, people {len(detail.get('People') or [])}, trailers {len(detail.get('RemoteTrailers') or [])}")
    people_ok = all(isinstance(p.get("Id"), str) for p in detail.get("People") or [])
    check("Cast entries have ids", people_ok)
    seasons = page("Seasons", f"Shows/{sid}/Seasons", {"userId": user})
    real = [s for s in seasons if (s.get("IndexNumber") or 0) >= 1]
    if seasons and (seasons[0].get("IndexNumber") or 0) == 0:
        notes.append("Specials come first in this show's season list (the page opens on season 1)")
    episodes = []
    if real or seasons:
        episodes = page("Episodes of a season", f"Shows/{sid}/Episodes", {"seasonId": (real or seasons)[0]["Id"], "Fields": "ProviderIds,Overview", "userId": user})
    page("Next up for the show", "Shows/NextUp", {"seriesId": sid, "userId": user, "Fields": "ProviderIds"})
    every = page("Every episode (diary matching, next season)", f"Shows/{sid}/Episodes", {"Fields": "ProviderIds", "userId": user})
    if len(every) > 1:
        after = page("Episode after (startItemId)", f"Shows/{sid}/Episodes", {"startItemId": every[0]["Id"], "Limit": 2, "Fields": "ProviderIds,Overview", "userId": user})
        check("startItemId starts at that episode", bool(after) and after[0]["Id"] == every[0]["Id"])
    page("Similar", f"Items/{sid}/Similar", {"Limit": 12, "Fields": "ProviderIds", "userId": user})
    items_array("Trailers (LocalTrailers)", f"Items/{sid}/LocalTrailers", {"userId": user})
    items_array("Special features", f"Items/{sid}/SpecialFeatures", {"userId": user})
    if detail.get("BackdropImageTags"):
        fetch("Show backdrop picture", f"Items/{sid}/Images/Backdrop", {"maxWidth": 1200, "quality": 90, "tag": detail["BackdropImageTags"][0]})
    people = [p for p in detail.get("People") or [] if p.get("PrimaryImageTag")]
    if people:
        fetch("Cast photo", f"Items/{people[0]['Id']}/Images/Primary", {"maxWidth": 300, "quality": 90, "tag": people[0]["PrimaryImageTag"]})
        person = get(f"Items/{people[0]['Id']}", {"userId": user})
        check("Person page (Items/{personId})", isinstance(person.get("Id"), str) and isinstance(person.get("Type"), str), person.get("Type"))
        page("Person's films and shows", "Items", {"Recursive": "true", "IncludeItemTypes": "Movie,Series", "PersonIds": people[0]["Id"], "Limit": 50, "userId": user})
    if detail.get("GenreItems"):
        page("Genre page", "Items", {"Recursive": "true", "IncludeItemTypes": "Movie,Series", "GenreIds": detail["GenreItems"][0]["Id"], "Limit": 50, "userId": user})

    print("\nAn episode in the player")
    episode = (episodes or every or [None])[0]
    if episode:
        eid = episode["Id"]
        print(f"  ({episode.get('Name')})")
        info_ = get(f"Items/{eid}", {"userId": user})
        sources = info_.get("MediaSources") or []
        check("Player extras (Items/{id})", bool(sources), f"{len(sources)} source(s), {len(info_.get('Chapters') or [])} chapters, trickplay {'yes' if info_.get('Trickplay') else 'no'}")
        streams = sources[0].get("MediaStreams") or [] if sources else []
        check("Media streams have an Index", all(isinstance(s.get("Index"), int) for s in streams), f"{len(streams)} streams")
        chapters_ok = all(isinstance(c.get("StartPositionTicks"), int) for c in info_.get("Chapters") or [])
        check("Chapters have start times", chapters_ok)
        segs = get(f"MediaSegments/{eid}")
        seg_ok = isinstance(segs.get("Items"), list) and all(isinstance(s.get("StartTicks"), int) and isinstance(s.get("EndTicks"), int) for s in segs["Items"])
        check("Intro and credits markers (MediaSegments)", seg_ok, ", ".join(s.get("Type", "?") for s in segs.get("Items", [])) or "none for this episode")
        data = get(f"UserItems/{eid}/UserData", {"userId": user})
        check("Saved place (UserItems/{id}/UserData)", isinstance(data, dict), f"position {data.get('PlaybackPositionTicks')}")
        fetch("Video stream (static, first KB)", f"Videos/{eid}/stream", {"static": "true", "api_key": KEY}, expect="any", ranged=True)
        trick = info_.get("Trickplay") or {}
        if trick:
            source_id, sizes = next(iter(trick.items()))
            width, t = sorted(sizes.items(), key=lambda kv: int(kv[0]))[0]
            need_ok, why = need(t, {"Width": int, "Height": int, "TileWidth": int, "TileHeight": int, "ThumbnailCount": int, "Interval": int}, "trickplay")
            check("Trickplay info fields", need_ok, why)
            fetch("Trickplay sheet", f"Videos/{eid}/Trickplay/{t['Width']}/0.jpg", {"mediaSourceId": source_id, "api_key": KEY})
        external = [s for s in streams if s.get("Type") == "Subtitle" and s.get("IsExternal")]
        if external and sources[0].get("Id"):
            s = external[0]
            fmt = "ass" if (s.get("Codec") or "").lower() in ("ass", "ssa") else "srt"
            fetch("Separate subtitle file", f"Videos/{eid}/{sources[0]['Id']}/Subtitles/{s['Index']}/Stream.{fmt}", {"api_key": KEY}, expect="any")
        else:
            notes.append("This episode has no separate subtitle files to test")
        if episode.get("ImageTags", {}).get("Primary"):
            fetch("Episode still", f"Items/{eid}/Images/Primary", {"maxWidth": 600, "quality": 90, "tag": episode["ImageTags"]["Primary"]})
        try:
            subs = get(f"Items/{eid}/RemoteSearch/Subtitles/eng", {"isPerfectMatch": "false"})
            check("Subtitle search (OpenSubtitles)", isinstance(subs, list) and all(isinstance(x.get("Id"), str) for x in subs), f"{len(subs)} results")
        except urllib.error.HTTPError as e:
            check("Subtitle search (OpenSubtitles)", False, f"HTTP {e.code}")

print("\nA film")
film = next((i for items in latest.values() for i in items if i["Type"] == "Movie"), None)
if film:
    fid = film["Id"]
    print(f"  ({film.get('Name')})")
    d = get(f"Items/{fid}", {"userId": user})
    check("Film page", isinstance(d.get("Id"), str), f"{len(d.get('MediaSources') or [])} version(s)")
    one = get("Items", {"Ids": fid, "Fields": "ProviderIds"})
    check("Item by id (Play)", isinstance(one.get("Items"), list) and len(one["Items"]) == 1, f"tmdb {((one.get('Items') or [{}])[0].get('ProviderIds') or {}).get('Tmdb')}")

print("\nA sample of shows (what the player will find)")
shows_lib = next((i for i, n, k in libraries if k == "tvshows"), None)
if shows_lib:
    sample = get("Items", {"ParentId": shows_lib, "Recursive": "false", "Limit": 12, "SortBy": "DateCreated", "SortOrder": "Descending", "userId": user}).get("Items", [])
    with_segments = with_trick = with_external = with_ass = decoded = missing = 0
    for show in sample:
        eps = get(f"Shows/{show['Id']}/Episodes", {"Limit": 1, "userId": user}).get("Items", [])
        if not eps:
            continue
        ep = get(f"Items/{eps[0]['Id']}", {"userId": user})
        decoded += 1
        source = (ep.get("MediaSources") or [{}])[0]
        streams = source.get("MediaStreams") or []
        with_trick += 1 if ep.get("Trickplay") else 0
        with_external += 1 if any(s.get("Type") == "Subtitle" and s.get("IsExternal") for s in streams) else 0
        with_ass += 1 if any(s.get("Type") == "Subtitle" and (s.get("Codec") or "").lower() in ("ass", "ssa") for s in streams) else 0
        with_segments += 1 if get(f"MediaSegments/{eps[0]['Id']}").get("Items") else 0
        missing += 0 if os.path.exists(source.get("Path") or "") else 1
    check("Sampled first episodes decode", decoded > 0, f"{decoded} shows")
    notes.append(f"of {decoded} sampled first episodes: {with_segments} have intro/credits markers, {with_trick} have trickplay, "
                 f"{with_external} have separate subtitle files, {with_ass} have ASS subtitles, {missing} are on a drive that isn't connected")

print(f"\n{passed} passed, {failed} failed")
for note in notes:
    print(f"  note: {note}")
sys.exit(1 if failed else 0)
