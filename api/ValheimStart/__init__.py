import logging

import azure.functions as func

from shared_code import valheim


def main(req: func.HttpRequest) -> func.HttpResponse:
    who = valheim.principal(req)
    if not who:
        return valheim.forbidden()

    try:
        body = req.get_json()
    except ValueError:
        body = {}
    region = (body or {}).get("region")
    if region not in valheim.REGIONS:
        return valheim.json_response(
            {"error": "region must be one of " + ", ".join(valheim.REGIONS)}, 400
        )

    try:
        # One world, one writer: never let two servers sync the same blob prefix.
        state = valheim.current_status()
        if state["state"] != "off":
            label = state.get("regionLabel") or state.get("region") or "another region"
            return valheim.json_response(
                {"error": f"Server is {state['state']} in {label}. Stop it first.",
                 "status": state}, 409
            )

        status, payload, name = valheim.start(region)
        if status not in (200, 201):
            logging.error("valheim: start rejected by ARM (%s) %s", status, payload)
            return valheim.json_response(
                {"error": "Azure rejected the deployment.", "detail": payload}, 502
            )
    except Exception:
        logging.exception("valheim: start failed")
        return valheim.json_response({"error": "Could not start the server."}, 502)

    logging.info("valheim: start by %s in %s (%s)", who.get("userDetails"), region, name)
    return valheim.json_response({"ok": True, "deployment": name, "region": region}, 202)
