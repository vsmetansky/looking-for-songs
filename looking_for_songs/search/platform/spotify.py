import os

import httpx

from looking_for_songs.search.platform import errors

TOKEN_URL = "https://accounts.spotify.com/api/token"
SEARCH_URL = "https://api.spotify.com/v1/search"


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


async def _search(
    c: httpx.AsyncClient, access_token: str, artist: str, name: str
) -> str | None:
    """Return the link to the first matching track, or None if there is none."""
    # Field filters keep artist and title from bleeding into each other.
    # Quotes are stripped so they can't terminate the filter early.
    query = (
        f'track:"{name.replace(chr(34), "")}" artist:"{artist.replace(chr(34), "")}"'
    )

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
        items = response.json()["tracks"]["items"]
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
    try:
        resp = await c.post(
            TOKEN_URL,
            data={"grant_type": "client_credentials"},
            auth=(client_id, client_secret),
        )
        resp.raise_for_status()
        payload = resp.json()
        return payload["access_token"]
    except httpx.HTTPError as exc:
        raise errors.UpstreamError(f"spotify auth failed: {exc}") from exc
    except (KeyError, ValueError) as exc:
        raise errors.UpstreamError("spotify auth returned an unexpected body") from exc
