import logging
import os

import azure.functions as func

from shared_code import valheim


def main(req: func.HttpRequest) -> func.HttpResponse:
    if not valheim.principal(req):
        return valheim.forbidden()
    try:
        return valheim.json_response(valheim.current_status())
    except Exception as exc:
        logging.exception("valheim: status failed")
        detail = repr(exc) if os.environ.get("VALHEIM_DEBUG_ERRORS") == "true" else None
        return valheim.json_response(
            {"error": "Could not read server status.", "detail": detail}, 502
        )
