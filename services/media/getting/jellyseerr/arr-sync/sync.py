"""Remove titles from Radarr/Sonarr after they were deleted in Jellyfin.

Seerr notices a deletion on its Jellyfin scan and marks the media "Deleted", but never
tells Radarr/Sonarr, so they keep the title monitored and list it as missing. An entry is
removed only when all of these hold, so re-requests and manual re-adds are left alone:
  - Seerr marks it Deleted,
  - Radarr/Sonarr has no files left for it,
  - its latest Radarr/Sonarr history event is a file deletion.
Files are never touched (deleteFiles=false) and no import exclusion is added.
Once no Radarr/Sonarr entry is left for it, the Seerr entry is cleared too (this also
drops its old requests), so the title can be requested again and Deleted entries do not
pile up.
"""
import json
import os
import urllib.parse
import urllib.request

SEERR = "http://jellyseerr.jellyseerr.svc:5055/api/v1"
RADARR = "http://radarr.radarr.svc:7878/api/v3"
SONARR = "http://sonarr.sonarr.svc:8989/api/v3"
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
SEERR_DELETED = 7


def call(base, key, path, method="GET", **params):
    url = base + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, method=method, headers={"X-Api-Key": key})
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read()
    return json.loads(body) if body else None


def seerr_deleted():
    key = os.environ["SEERR_API_KEY"]
    page, skip = [], 0
    while True:
        data = call(SEERR, key, "/media", filter="all", take=100, skip=skip)
        page += [m for m in data["results"] if m.get("status") == SEERR_DELETED]
        skip += 100
        if skip >= data["pageInfo"]["results"]:
            return page


def last_event(history):
    return max(history, key=lambda h: h["date"])["eventType"] if history else None


def remove(base, key, kind, item, title, **params):
    action = "would remove" if DRY_RUN else "removing"
    print(f"{action} {kind} {title} (id {item['id']})", flush=True)
    if not DRY_RUN:
        call(base, key, f"/{kind}/{item['id']}", method="DELETE", deleteFiles="false", **params)


def sync_movie(media):
    """Returns True when no Radarr entry is left for the media."""
    key = os.environ["RADARR_API_KEY"]
    kept = False
    for movie in call(RADARR, key, "/movie", tmdbId=media["tmdbId"]):
        title = f"{movie['title']} ({movie.get('year')})"
        if movie.get("hasFile"):
            print(f"keep movie {title}: has a file again", flush=True)
            kept = True
            continue
        if last_event(call(RADARR, key, "/history/movie", movieId=movie["id"])) != "movieFileDeleted":
            print(f"keep movie {title}: last history event is not a file deletion", flush=True)
            kept = True
            continue
        remove(RADARR, key, "movie", movie, title, addImportExclusion="false")
    return not kept


def sync_series(media):
    """Returns True when no Sonarr entry is left for the media."""
    if not media.get("tvdbId"):
        print(f"keep Seerr media {media['id']}: no TVDB id to look it up in Sonarr", flush=True)
        return False
    key = os.environ["SONARR_API_KEY"]
    kept = False
    for series in call(SONARR, key, "/series", tvdbId=media["tvdbId"]):
        title = series["title"]
        if series.get("statistics", {}).get("episodeFileCount", 0) > 0:
            print(f"keep series {title}: still has episode files", flush=True)
            kept = True
            continue
        if last_event(call(SONARR, key, "/history/series", seriesId=series["id"])) != "episodeFileDeleted":
            print(f"keep series {title}: last history event is not a file deletion", flush=True)
            kept = True
            continue
        remove(SONARR, key, "series", series, title, addImportListExclusion="false")
    return not kept


def clear_seerr(media):
    action = "would clear" if DRY_RUN else "clearing"
    print(f"{action} Seerr {media['mediaType']} tmdb {media['tmdbId']} (media {media['id']})", flush=True)
    if not DRY_RUN:
        call(SEERR, os.environ["SEERR_API_KEY"], f"/media/{media['id']}", method="DELETE")


def main():
    deleted = seerr_deleted()
    print(f"{len(deleted)} media marked Deleted in Seerr{' (dry run)' if DRY_RUN else ''}", flush=True)
    for media in deleted:
        if (sync_movie if media["mediaType"] == "movie" else sync_series)(media):
            clear_seerr(media)


if __name__ == "__main__":
    main()
