import logging

import azure.functions as func

from shared_code import valheim


def main(req: func.HttpRequest) -> func.HttpResponse:
    who = valheim.principal(req)
    if not who:
        return valheim.forbidden()

    try:
        status, payload = valheim.stop()
    except Exception:
        logging.exception("valheim: stop failed")
        return valheim.json_response({"error": "Could not reach the server."}, 502)

    if status == 404:
        return valheim.json_response({"error": "No server is running."}, 409)
    if status not in (200, 202):
        logging.error("valheim: stop rejected by ARM (%s) %s", status, payload)
        return valheim.json_response({"error": "Azure rejected the stop request."}, 502)

    logging.info("valheim: stop by %s", who.get("userDetails"))
    return valheim.json_response(
        {"ok": True,
         "message": "Server is saving and shutting down. Resources disappear in 3-5 minutes."},
        202,
    )
