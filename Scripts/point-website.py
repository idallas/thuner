#!/usr/bin/env python3
"""Points the ThUNER page's download button at a version, and versions the pages' stylesheet and image URLs (?v=…).

The server tells browsers to keep stylesheets and images for 30 days, so a changed screenshot or style under the
same URL goes unseen. Used by release.sh (stable releases) and promote-release.sh.

    Scripts/point-website.py <version> <download url> <thuner page> <overview page>
"""
import re
import sys

version, url, page, overview = sys.argv[1:5]
for path in (page, overview):
    html = open(path).read()
    if path == page:
        # data-umami-event makes Umami count clicks as a "Download ThUNER" event, with the version attached.
        button = (f'<a class="button" href="{url}" data-umami-event="Download ThUNER" '
                  f'data-umami-event-version="{version}">Download ThUNER {version}</a>')
        html = re.sub(r"<!-- download -->.*?<!-- /download -->", f"<!-- download -->{button}<!-- /download -->",
                      html, flags=re.S)
    html = re.sub(r'((?:href|src)="[^"?]+\.(?:css|png|jpg|webp))(?:\?v=[^"]*)?"', rf'\1?v={version}"', html)
    open(path, "w").write(html)
