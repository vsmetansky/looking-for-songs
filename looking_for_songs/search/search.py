from looking_for_songs.search.platform import spotify


async def search(artist: str, name: str, platform: str) -> str | None:
    """Return a link to the song on `platform`, or None if it was not found."""

    if platform == "spotify":
        return await spotify.search(artist, name)

    raise ValueError(f"unsupported platform: {platform}")
