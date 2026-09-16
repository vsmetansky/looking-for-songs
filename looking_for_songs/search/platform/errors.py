class ConfigurationError(Exception):
    """The platform is supported but this deployment isn't set up to reach it."""


class UpstreamError(Exception):
    """The platform's API was unreachable or returned something unusable."""
