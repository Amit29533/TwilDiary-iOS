"""A small stand-in Jellyfin server for the QA run's JellySpace UI tests: two libraries (films and
shows), a film to resume, a favourite, a show's next episode, posters and backdrops, and every video
streamed from the test video. It answers what JellySpace asks with the shapes Jellyfin uses, waits a
little on each request (as a home network does), and logs every request for the run's summary.
Usage: fake_jellyfin.py <folder with qa.mkv, poster.jpg, backdrop.jpg> <port> <log file>"""
import http.server
import json
import os
import re
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse

FOLDER, PORT, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3]
DELAY = float(os.environ.get('QA_DELAY_MS', '60')) / 1000
TICKS = 10_000_000
LENGTH = 600 * TICKS
USER = 'qa-user'
lock = threading.Lock()


def stream_list():
    return [
        {'Type': 'Video', 'Index': 0, 'Codec': 'h264', 'Width': 1920, 'Height': 1080, 'RealFrameRate': 24.0, 'DisplayTitle': '1080p H264', 'IsDefault': True},
        {'Type': 'Audio', 'Index': 1, 'Codec': 'aac', 'Language': 'eng', 'DisplayTitle': 'English - AAC - Stereo', 'Channels': 2, 'IsDefault': True},
        {'Type': 'Audio', 'Index': 2, 'Codec': 'aac', 'Language': 'jpn', 'DisplayTitle': 'Japanese - AAC - Stereo', 'Channels': 2},
        {'Type': 'Subtitle', 'Index': 3, 'Codec': 'ass', 'Language': 'eng', 'DisplayTitle': 'English - ASS', 'IsDefault': True, 'IsExternal': False},
        {'Type': 'Subtitle', 'Index': 4, 'Codec': 'subrip', 'Language': 'spa', 'DisplayTitle': 'Spanish - SRT', 'IsExternal': False},
    ]


def base(item_id, name, kind, **extra):
    item = {'Id': item_id, 'Name': name, 'Type': kind, 'ImageTags': {'Primary': 'p-' + item_id}, 'BackdropImageTags': ['b-' + item_id],
            'UserData': {'PlaybackPositionTicks': 0, 'Played': False, 'IsFavorite': False, 'PlayedPercentage': 0},
            'ProviderIds': {}, 'Genres': ['Drama'], 'Overview': f'{name}: a test title for the QA run.', 'CommunityRating': 7.4,
            'OfficialRating': 'PG-13', 'PrimaryImageAspectRatio': 0.6667, 'DateCreated': '2026-11-01T10:00:00.0000000Z'}
    item.update(extra)
    return item


FILMS = [('m1', 'Quiet Orbit', 2016, ['Science Fiction', 'Drama']), ('m2', 'Paper Lantern', 2018, ['Drama']),
         ('m3', 'Glass Harbor', 2019, ['Thriller']), ('m4', 'Night Signal', 2020, ['Science Fiction']),
         ('m5', 'Iron Meadow', 2021, ['Western']), ('m6', 'Blue Comet', 2022, ['Animation', 'Family']),
         ('m7', 'Silent Atlas', 2023, ['Adventure']), ('m8', 'Copper Sky', 2024, ['Drama', 'Romance'])]
ITEMS = {}
for index, (item_id, name, year, genres) in enumerate(FILMS):
    ITEMS[item_id] = base(item_id, name, 'Movie', ProductionYear=year, Genres=genres, RunTimeTicks=LENGTH, ParentId='lib-movies',
                          Path=f'/media/films/{name}.mkv', DateCreated=f'2026-11-{10 + index:02d}T10:00:00.0000000Z')
# A film with only a wide picture (what broke the posters: a landscape image as its Primary).
ITEMS['m-wide'] = base('m-wide', 'Wide Horizon', 'Movie', ProductionYear=2015, RunTimeTicks=LENGTH, ParentId='lib-movies',
                       PrimaryImageAspectRatio=1.7778, Path='/media/films/Wide Horizon.mkv', ImageTags={'Primary': 'wide'})
ITEMS['m2']['UserData'].update(PlaybackPositionTicks=60 * TICKS, PlayedPercentage=10, LastPlayedDate='2026-11-21T20:00:00.0000000Z')
ITEMS['m3']['UserData'].update(IsFavorite=True)

SHOWS = [('s1', 'Harbor Lights', 2, 4), ('s2', 'Clockwork Garden', 1, 6)]
for show_id, name, seasons, episodes in SHOWS:
    ITEMS[show_id] = base(show_id, name, 'Series', ProductionYear=2020, ParentId='lib-shows', Path=f'/media/shows/{name}', IsFolder=True,
                          UserData={'PlaybackPositionTicks': 0, 'Played': False, 'IsFavorite': False, 'UnplayedItemCount': seasons * episodes})
    for s in range(1, seasons + 1):
        season_id = f'{show_id}-s{s}'
        ITEMS[season_id] = base(season_id, f'Season {s}', 'Season', IndexNumber=s, SeriesId=show_id, SeriesName=name, ParentId=show_id, IsFolder=True)
        for e in range(1, episodes + 1):
            episode_id = f'{show_id}-s{s}e{e}'
            ITEMS[episode_id] = base(episode_id, f'Episode {e} of season {s}', 'Episode', IndexNumber=e, ParentIndexNumber=s, SeriesId=show_id,
                                     SeriesName=name, SeasonId=season_id, ParentId=season_id, RunTimeTicks=LENGTH, PrimaryImageAspectRatio=1.7778,
                                     SeriesPrimaryImageTag='p-' + show_id, Path=f'/media/shows/{name}/S{s:02d}E{e:02d}.mkv')
ITEMS['s1-s1e1']['UserData'].update(Played=True)
LIBRARIES = [{'Id': 'lib-movies', 'Name': 'Films', 'CollectionType': 'movies', 'Type': 'CollectionFolder'},
             {'Id': 'lib-shows', 'Name': 'Shows', 'CollectionType': 'tvshows', 'Type': 'CollectionFolder'}]


def full(item):
    """An item as Items/{id} gives it: with its file, tracks and chapters."""
    out = dict(item)
    if item['Type'] in ('Movie', 'Episode'):
        out['MediaSources'] = [{'Id': item['Id'], 'Name': item['Name'], 'Size': 300_000_000, 'Bitrate': 4_000_000, 'Container': 'mkv',
                                'MediaStreams': stream_list(), 'MediaAttachments': []}]
        out['MediaStreams'] = stream_list()
        out['Chapters'] = [{'StartPositionTicks': i * 120 * TICKS, 'Name': f'Chapter {i + 1}'} for i in range(5)]
        out['People'] = [{'Id': 'p1', 'Name': 'Ada Test', 'Role': 'Lead', 'Type': 'Actor'}]
    if item['Type'] == 'Series':
        out['People'] = [{'Id': 'p1', 'Name': 'Ada Test', 'Role': 'Lead', 'Type': 'Actor'}]
    return out


def page(items):
    return {'Items': items, 'TotalRecordCount': len(items), 'StartIndex': 0}


def children(parent):
    return [i for i in ITEMS.values() if i.get('ParentId') == parent]


def query_items(q):
    found = list(ITEMS.values())
    if 'Ids' in q or 'ids' in q:
        wanted = (q.get('Ids') or q.get('ids'))[0].split(',')
        return [ITEMS[i] for i in wanted if i in ITEMS]
    parent = (q.get('ParentId') or q.get('parentId') or [None])[0]
    recursive = (q.get('Recursive') or q.get('recursive') or ['false'])[0].lower() == 'true'
    if parent:
        if recursive:
            def under(item):
                at = item
                while at and at.get('ParentId'):
                    if at['ParentId'] == parent:
                        return True
                    at = ITEMS.get(at['ParentId'])
                return False
            found = [i for i in found if under(i)]
        else:
            found = children(parent)
    types = (q.get('IncludeItemTypes') or q.get('includeItemTypes') or [''])[0]
    if types:
        allowed = set(types.split(','))
        found = [i for i in found if i['Type'] in allowed]
    term = (q.get('searchTerm') or q.get('SearchTerm') or [''])[0].lower()
    if term:
        found = [i for i in found if term in i['Name'].lower() or term in i.get('SeriesName', '').lower()]
    filters = (q.get('Filters') or q.get('filters') or [''])[0]
    if 'IsFavorite' in filters:
        found = [i for i in found if i['UserData'].get('IsFavorite')]
    if 'IsResumable' in filters:
        found = [i for i in found if i['UserData'].get('PlaybackPositionTicks')]
    if 'IsUnplayed' in filters:
        found = [i for i in found if not i['UserData'].get('Played')]
    sort = (q.get('SortBy') or q.get('sortBy') or [''])[0]
    if 'DateCreated' in sort:
        found.sort(key=lambda i: i.get('DateCreated', ''), reverse=True)
    elif 'Random' not in sort:
        found.sort(key=lambda i: (i.get('ParentIndexNumber', 0), i.get('IndexNumber', 0), i['Name']))
    start = int((q.get('StartIndex') or q.get('startIndex') or ['0'])[0])
    limit = int((q.get('Limit') or q.get('limit') or ['1000'])[0])
    return found[start:start + limit]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log(self, status, started):
        with lock, open(LOG, 'a') as f:
            f.write(f'{time.time():.3f}\t{self.command}\t{status}\t{(time.time() - started) * 1000:.0f}\t{self.path}\n')

    def send_json(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        return status

    def send_file(self, name, content_type):
        path = os.path.join(FOLDER, name)
        size = os.path.getsize(path)
        match = re.match(r'bytes=(\d*)-(\d*)', self.headers.get('Range', ''))
        start, end = 0, size - 1
        if match:
            if match.group(1):
                start = int(match.group(1))
                if match.group(2):
                    end = min(int(match.group(2)), size - 1)
            elif match.group(2):
                start = max(0, size - int(match.group(2)))
            if start >= size:
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{size}')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return 416
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        else:
            self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        self.end_headers()
        if self.command == 'HEAD':
            return 206 if match else 200
        with open(path, 'rb') as f:
            f.seek(start)
            left = end - start + 1
            try:
                while left > 0:
                    chunk = f.read(min(65536, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass
        return 206 if match else 200

    def empty(self, status=204):
        self.send_response(status)
        self.send_header('Content-Length', '0')
        self.end_headers()
        return status

    def route(self):
        url = urlparse(self.path)
        path = url.path.rstrip('/')
        q = parse_qs(url.query)
        parts = [p for p in path.split('/') if p]
        lower = path.lower()
        if '/images/' in lower:
            kind = parts[parts.index('Images') + 1] if 'Images' in parts else 'Primary'
            item = ITEMS.get(parts[1]) if len(parts) > 1 else None
            if kind == 'Logo':
                return self.empty(404)
            wide = kind in ('Backdrop', 'Thumb') or (item and item['Type'] == 'Episode') or (item and item['Id'] == 'm-wide')
            return self.send_file('backdrop.jpg' if wide else 'poster.jpg', 'image/jpeg')
        if re.match(r'^/videos/[^/]+/(stream|main)', lower) or lower.endswith('/stream.mkv'):
            return self.send_file('qa.mkv', 'video/x-matroska')
        if lower.startswith('/videos/') and '/trickplay/' in lower:
            return self.empty(404)
        if self.command in ('POST', 'DELETE'):
            length = int(self.headers.get('Content-Length', '0') or 0)
            if length:
                self.rfile.read(length)
            return self.empty(204)
        if lower in ('/system/info/public', '/system/info'):
            return self.send_json({'Id': 'qa-server', 'ServerName': 'QA Jellyfin', 'Version': '10.11.2', 'LocalAddress': f'http://127.0.0.1:{PORT}'})
        if lower == '/users' or lower == '/users/me' or lower.startswith('/users/'):
            row = {'Id': USER, 'Name': 'qa', 'Policy': {'IsAdministrator': True, 'EnableContentDeletion': True}}
            return self.send_json([row] if lower == '/users' else row)
        if lower == '/userviews':
            return self.send_json(page(LIBRARIES))
        if lower == '/library/virtualfolders':
            return self.send_json([{'Name': l['Name'], 'CollectionType': l['CollectionType'], 'ItemId': l['Id']} for l in LIBRARIES])
        if lower == '/useritems/resume':
            return self.send_json(page([i for i in ITEMS.values() if i['UserData'].get('PlaybackPositionTicks')]))
        if lower == '/shows/nextup':
            series = (q.get('seriesId') or [None])[0]
            nexts = [ITEMS['s1-s1e2'], ITEMS['s2-s1e1']]
            return self.send_json(page([n for n in nexts if not series or n['SeriesId'] == series]))
        if lower == '/items/latest':
            parent = (q.get('parentId') or q.get('ParentId') or [''])[0]
            found = sorted([i for i in ITEMS.values() if i.get('ParentId') == parent], key=lambda i: i.get('DateCreated', ''), reverse=True)
            return self.send_json(found[:int((q.get('Limit') or ['16'])[0])])
        match = re.match(r'^/shows/([^/]+)/seasons$', lower)
        if match:
            return self.send_json(page(sorted(children(parts[1]), key=lambda i: i.get('IndexNumber', 0))))
        match = re.match(r'^/shows/([^/]+)/episodes$', lower)
        if match:
            season = (q.get('seasonId') or q.get('SeasonId') or [None])[0]
            found = [i for i in ITEMS.values() if i['Type'] == 'Episode' and i['SeriesId'] == parts[1] and (not season or i['SeasonId'] == season)]
            found.sort(key=lambda i: (i['ParentIndexNumber'], i['IndexNumber']))
            limit = int((q.get('Limit') or ['1000'])[0])
            return self.send_json(page(found[:limit]))
        match = re.match(r'^/useritems/([^/]+)/userdata$', lower)
        if match:
            item = ITEMS.get(parts[1])
            return self.send_json((item or {}).get('UserData', {'PlaybackPositionTicks': 0, 'Played': False}))
        match = re.match(r'^/items/([^/]+)/similar$', lower)
        if match:
            return self.send_json(page([i for i in ITEMS.values() if i['Type'] == 'Movie' and i['Id'] != parts[1]][:6]))
        if lower == '/items':
            return self.send_json(page(query_items(q)))
        match = re.match(r'^/items/([^/]+)$', lower)
        if match:
            item = ITEMS.get(parts[1])
            return self.send_json(full(item)) if item else self.send_json({'error': 'not found'}, 404)
        if lower.startswith('/mediasegments/'):
            return self.send_json({'Items': [], 'TotalRecordCount': 0})
        if lower in ('/genres', '/studios', '/persons', '/artists') or lower.startswith('/items/filters'):
            return self.send_json(page([]))
        if lower.startswith('/sessions') or lower.startswith('/playback'):
            return self.empty(204)
        return self.send_json(page([]))

    def handle_any(self):
        started = time.time()
        time.sleep(DELAY)
        try:
            status = self.route()
        except Exception as error:  # noqa: BLE001
            status = self.send_json({'error': str(error)}, 500)
        self.log(status, started)

    do_GET = do_POST = do_DELETE = do_HEAD = handle_any

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
