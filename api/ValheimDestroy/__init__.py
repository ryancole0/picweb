import logging

import azure.functions as func

from shared_code import valheim


def main(req: func.HttpRequest) -> func.HttpResponse:
    who = valheim.principal(req)
    if not who:
        return valheim.forbidden()

    try:
        status, payload, name = valheim.destroy()
    except Exception:
        logging.exception("valheim: destroy failed")
        return valheim.json_response({"error": "Could not start the delete."}, 502)

    if status not in (200, 201):
        logging.error("valheim: destroy rejected by ARM (%s) %s", status, payload)
        return valheim.json_response({"error": "Azure rejected the delete."}, 502)

    logging.warning("valheim: FORCE destroy by %s", who.get("userDetails"))
    return valheim.json_response(
        {"ok": True, "deployment": name, "message": "Force-deleting all server resources."}, 202
    )
