"""Fail closed unless the latest official Codemagic check passed this exact SHA."""
import json
import os
import sys

CHECK_NAME = "TwilDiary native iOS — unsigned regression"


def accepted_check(pages, sha):
    checks = [check for page in pages for check in page.get("check_runs", [])
              if check.get("head_sha") == sha
              and check.get("app", {}).get("slug") == "codemagic-ci-cd"
              and check.get("name") == CHECK_NAME]
    if not checks:
        raise ValueError("No official Codemagic regression check exists for this source commit.")
    latest = max(checks, key=lambda check: check["id"])
    if latest.get("status") != "completed" or latest.get("conclusion") != "success":
        raise ValueError("Latest Codemagic regression is not a completed success: "
                         + str(latest.get("conclusion") or latest.get("status")))
    return latest


if __name__ == "__main__":
    try:
        with open(sys.argv[1], encoding="utf-8") as source:
            check = accepted_check(json.load(source), sys.argv[2])
    except (ValueError, KeyError, IndexError, TypeError) as error:
        sys.exit("Promotion blocked: " + str(error))
    print("Codemagic accepted exact source " + sys.argv[2] + ": " + check["html_url"])
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write("check_url=" + check["html_url"] + "\n")
