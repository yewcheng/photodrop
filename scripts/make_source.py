#!/usr/bin/env python3
"""Write the SideStore source document.

Usage: make_source.py <version> <size-bytes> <iso-date> <download-url>
"""

import json
import sys

ICON_URL = "https://raw.githubusercontent.com/yewcheng/photodrop/main/icon.png"
DESCRIPTION = "Copies original photos, videos and Live Photos to your own laptop over Tailscale."

version, size, date, url = sys.argv[1:5]
print(json.dumps({
    "name": "PhotoDrop",
    "identifier": "com.photodrop.source",
    "subtitle": "Original photos to your laptop",
    "iconURL": ICON_URL,
    "apps": [{
        "name": "PhotoDrop",
        "bundleIdentifier": "com.photodrop.backup",
        "developerName": "yewcheng",
        "subtitle": "Original photos to your laptop",
        "localizedDescription": DESCRIPTION,
        # Required: SideStore refuses the whole source without it.
        "iconURL": ICON_URL,
        "tintColor": "1E6FD9",
        "category": "utilities",
        "screenshotURLs": [],
        "versions": [{
            "version": version,
            "date": date,
            "localizedDescription": "Automated build.",
            "downloadURL": url,
            "size": int(size),
            "minOSVersion": "16.0",
        }],
        # Older clients read these flat fields instead of `versions`.
        "version": version,
        "versionDate": date,
        "versionDescription": "Automated build.",
        "downloadURL": url,
        "size": int(size),
    }],
    "news": [],
}, indent=2))
