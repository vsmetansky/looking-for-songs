import logging
import os
from typing import Any

from starlette.applications import Starlette
from starlette.exceptions import HTTPException
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from looking_for_songs.search import search as s
from looking_for_songs.search.platform import errors

logger = logging.getLogger(__name__)

SUPPORTED_PLATFORMS = ("spotify",)


async def look(request: Request) -> JSONResponse:
    try:
        body: dict[Any, Any] = await request.json()
    except ValueError:
        raise HTTPException(400, detail="Request body must be valid JSON") from None
    if not isinstance(body, dict) or not body:
        raise HTTPException(400, detail="Your body is empty")

    artist = _required_str(body, "artist", 'Pass in `artist` in request body')
    name = _required_str(body, "name", 'Pass in song `name` in request body')
    platform = _required_str(
        body,
        "platform",
        f'Pass in `platform` in request body. Supported values: {", ".join(SUPPORTED_PLATFORMS)}',
    )

    if platform not in SUPPORTED_PLATFORMS:
        raise HTTPException(
            400, detail=f"Supported platforms: {', '.join(SUPPORTED_PLATFORMS)}"
        )

    try:
        link = await s.search(artist, name, platform)
    except errors.ConfigurationError as exc:
        logger.error("%s is not configured: %s", platform, exc)
        raise HTTPException(503, detail=f"{platform} search is not configured") from exc
    except errors.UpstreamError as exc:
        logger.warning("%s lookup failed: %s", platform, exc)
        raise HTTPException(502, detail=f"{platform} could not be reached") from exc

    if link is None:
        raise HTTPException(
            404, detail=f'"{name}" by {artist} was not found on {platform}'
        )

    return JSONResponse({"link": link})


def _required_str(body: dict[Any, Any], key: str, detail: str) -> str:
    """Read a non-empty string field, rejecting missing and non-string values alike."""
    value = body.get(key)
    if not isinstance(value, str) or not value.strip():
        raise HTTPException(400, detail=detail)
    return value.strip()


def run() -> None:
    import uvicorn

    app = Starlette(
        routes=[Route("/api/look", look, methods=["POST"])],
    )
    logging.basicConfig(level=logging.INFO)
    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8080"))

    uvicorn.run(app, host=host, port=port)
