import asyncio
import logging
import os
import time

import httpx

from looking_for_songs.search.platform import errors

ACCESS_TOKEN_URL = "https://accounts.spotify.com/api/token"
ACCESS_TOKEN: str | None = None
ACCESS_TOKEN_EXPIRES_AT = 0.0
ACCESS_TOKEN_EXPIRY_MARGIN_S = 60  # to refresh a bit earlier just in case

SEARCH_URL = "https://api.spotify.com/v1/search"

_ACCESS_TOKEN_LOCK = asyncio.Lock()

logger = logging.getLogger(__name__)


async def search(artist: str, name: str) -> str | None:
    async with httpx.AsyncClient() as c:
        client_id = os.environ.get("SPOTIFY_CLIENT_ID")
        client_secret = os.environ.get("SPOTIFY_CLIENT_SECRET")

        if not client_id or not client_secret:
            raise errors.ConfigurationError(
                "SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET must be set"
            )

        access_token = await _obtain_access_token(c, client_id, client_secret)
        return await _search(c, access_token, artist, name)


def _strip_parenthetical(title: str) -> str:
    """Drop a parenthetical such as "(with X)", "(feat. Y)" or "(Remastered)".

    Apple Music folds featured artists into the title -- "Marechia (with Celia
    Kameni)" where Spotify stores plain "Marechia" -- so dropping the
    parenthetical is what makes the two catalogues agree.

    Returns "" when the title opens with the paren, as in "(Don't Fear) The
    Reaper": no usable stem is left, and callers read that as "no fallback".
    """
    return title.partition("(")[0].strip()


async def _search(
    c: httpx.AsyncClient, access_token: str, artist: str, name: str
) -> str | None:
    """Return the link to the first matching track, or None if there is none."""
    link = await _search_once(c, access_token, artist, name)
    if link is not None:
        return link

    # Strictly a fallback: an exact title has to win, because stripping also
    # discards parentheticals that genuinely name a different recording, like
    # "(Reprise)" or "(Live)".
    stem = _strip_parenthetical(name)
    if not stem or stem == name.strip():
        return None

    logger.info(
        'No match for "%s"; retrying without its parenthetical as "%s"', name, stem
    )
    return await _search_once(c, access_token, artist, stem)


async def _search_once(
    c: httpx.AsyncClient, access_token: str, artist: str, name: str
) -> str | None:
    """Run a single search and return the first track's link, or None."""
    # Field filters keep artist and title from bleeding into each other.
    # Quotes are stripped so they can't terminate the filter early.
    track = name.replace('"', "")
    performer = artist.replace('"', "")
    query = f'track:"{track}" artist:"{performer}"'

    try:
        response = await c.get(
            SEARCH_URL,
            params={"q": query, "type": "track", "limit": 1},
            headers={"Authorization": f"Bearer {access_token}"},
        )
    except httpx.HTTPError as exc:
        raise errors.UpstreamError(f"spotify search failed: {exc}") from exc

    try:
        response.raise_for_status()
        response_json = response.json()

        logger.info(response_json)

        items = response_json["tracks"]["items"]
    except httpx.HTTPError as exc:
        raise errors.UpstreamError(f"spotify search failed: {exc}") from exc
    except (KeyError, TypeError, ValueError) as exc:
        raise errors.UpstreamError(
            "spotify search returned an unexpected body"
        ) from exc

    if not items:
        return None
    return items[0].get("external_urls", {}).get("spotify")


async def _obtain_access_token(
    c: httpx.AsyncClient, client_id: str, client_secret: str
) -> str:
    global ACCESS_TOKEN, ACCESS_TOKEN_EXPIRES_AT

    if ACCESS_TOKEN is not None and time.monotonic() < ACCESS_TOKEN_EXPIRES_AT:
        return ACCESS_TOKEN

    async with _ACCESS_TOKEN_LOCK:
        # a concurrent request might have obtained a fresh access token,
        # retry returning the token from the cache
        if ACCESS_TOKEN is not None and time.monotonic() < ACCESS_TOKEN_EXPIRES_AT:
            return ACCESS_TOKEN
        try:
            resp = await c.post(
                ACCESS_TOKEN_URL,
                data={"grant_type": "client_credentials"},
                auth=(client_id, client_secret),
            )
            resp.raise_for_status()
            payload = resp.json()

            ACCESS_TOKEN_EXPIRES_AT = (
                time.monotonic() + payload["expires_in"] - ACCESS_TOKEN_EXPIRY_MARGIN_S
            )
            ACCESS_TOKEN = payload["access_token"]
            if ACCESS_TOKEN is None:
                raise errors.UpstreamError("spotify auth returned a null access token")

            return ACCESS_TOKEN
        except httpx.HTTPError as exc:
            raise errors.UpstreamError(f"spotify auth failed: {exc}") from exc
        except (KeyError, ValueError) as exc:
            raise errors.UpstreamError(
                "spotify auth returned an unexpected body"
            ) from exc
