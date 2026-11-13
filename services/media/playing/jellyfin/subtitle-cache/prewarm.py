"""Extract embedded subtitles before anyone presses play.

Jellyfin extracts embedded subtitles the first time a client asks for one: ffmpeg reads the
whole video file once and writes every extractable subtitle stream to its cache on the config
volume. The media library is on the NAS, so that read runs at network speed, and the first
play of a large file with text subtitles waits minutes while files without them start at once.

This job asks Jellyfin for one embedded text subtitle per file, newest items first, so the
extraction happens at night. Files already in the cache answer at once, so every run walks
the whole library and continues where the last one stopped. It stops starting new extractions
when the time budget is used up, while someone is watching, or when the config volume runs low
on space (the cache also holds image-based subtitles, which can be tens of MB per stream).
"""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

JELLYFIN = "http://jellyfin.jellyfin.svc.cluster.local:8096"
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
# Stop starting extractions after this many minutes (keep below activeDeadlineSeconds)
BUDGET_MINUTES = int(os.environ.get("BUDGET_MINUTES", "210"))
# Leave at least this much free on the volume that holds Jellyfin's data folder
MIN_FREE_GB = float(os.environ.get("MIN_FREE_GB", "3"))
# Matches Jellyfin's SubtitleExtractionTimeoutMinutes (30) plus a margin
EXTRACT_TIMEOUT = 35 * 60
PAGE = 200
# Ask in the stream's own format so Jellyfin only extracts, never converts
FORMATS = {"subrip": "srt", "srt": "srt", "ass": "ass", "ssa": "ssa", "webvtt": "vtt"}

START = time.monotonic()


def call(path, timeout=60, raw=False, **params):
    url = JELLYFIN + path + ("?" + urllib.parse.urlencode(params) if params else "")
    headers = {"Authorization": f'MediaBrowser Token="{os.environ["JELLYFIN_API_KEY"]}"'}
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read()
    return body if raw else (json.loads(body) if body else None)


def minutes_used():
    return (time.monotonic() - START) / 60


def free_gb():
    # ProgramDataFolder is the config volume, where the subtitle cache lives
    return call("/System/Info/Storage")["ProgramDataFolder"]["FreeSpace"] / 1e9


def someone_watching():
    return any(s.get("NowPlayingItem") for s in call("/Sessions", activeWithinSeconds=120))


def items():
    start = 0
    while True:
        page = call(
            "/Items",
            Recursive="true",
            IncludeItemTypes="Movie,Episode",
            HasSubtitles="true",
            Fields="MediaSources",
            SortBy="DateCreated",
            SortOrder="Descending",
            StartIndex=start,
            Limit=PAGE,
        )
        yield from page["Items"]
        start += PAGE
        if start >= page["TotalRecordCount"]:
            return


def first_embedded_text_subtitle(source):
    for stream in source.get("MediaStreams") or []:
        if (
            stream.get("Type") == "Subtitle"
            and not stream.get("IsExternal")
            and stream.get("IsTextSubtitleStream")
        ):
            return stream
    return None


def main():
    seen = cached = extracted = 0
    pending_bytes = image_streams = 0
    for item in items():
        for source in item.get("MediaSources") or []:
            if source.get("Protocol") != "File":
                continue
            stream = first_embedded_text_subtitle(source)
            if stream is None:
                continue
            seen += 1
            size_gb = (source.get("Size") or 0) / 1e9
            label = f"{item.get('SeriesName', '') + ' ' if item.get('SeriesName') else ''}{item['Name']} ({size_gb:.1f} GB)"
            if DRY_RUN:
                pending_bytes += source.get("Size") or 0
                image_streams += sum(
                    1
                    for s in source.get("MediaStreams") or []
                    if s.get("Type") == "Subtitle"
                    and not s.get("IsExternal")
                    and not s.get("IsTextSubtitleStream")
                )
                continue
            if minutes_used() > BUDGET_MINUTES:
                print(f"time budget used after {seen} files; next run continues", flush=True)
                return summary(seen, cached, extracted)
            fmt = FORMATS.get((stream.get("Codec") or "").lower(), "srt")
            path = f"/Videos/{item['Id']}/{source['Id']}/Subtitles/{stream['Index']}/0/Stream.{fmt}"
            # An extraction fills the NAS link for minutes: never start one while someone is
            # streaming or the volume is nearly full. (A cached file costs only these checks.)
            while someone_watching():
                if minutes_used() > BUDGET_MINUTES:
                    print("someone is watching and the time budget is used up", flush=True)
                    return summary(seen, cached, extracted)
                print("someone is watching; waiting", flush=True)
                time.sleep(300)
            if free_gb() < MIN_FREE_GB:
                print(f"stopping: less than {MIN_FREE_GB} GB free on the config volume", flush=True)
                return summary(seen, cached, extracted)
            began = time.monotonic()
            try:
                call(path, timeout=EXTRACT_TIMEOUT, raw=True)
            except (TimeoutError, urllib.error.URLError) as err:
                print(f"failed {label}: {err}", flush=True)
                continue
            took = time.monotonic() - began
            if took < 3:
                cached += 1
                continue
            extracted += 1
            print(f"extracted {label} in {took:.0f}s", flush=True)
    if DRY_RUN:
        print(f"{seen} files with embedded text subtitles, {pending_bytes / 1e12:.2f} TB to read "
              f"if none is cached, {image_streams} image subtitle streams extracted with them; "
              f"{free_gb():.1f} GB free on the config volume", flush=True)
        return
    summary(seen, cached, extracted)


def summary(seen, cached, extracted):
    print(f"done: {seen} files with embedded text subtitles, {cached} already cached, "
          f"{extracted} extracted this run", flush=True)


if __name__ == "__main__":
    main()
