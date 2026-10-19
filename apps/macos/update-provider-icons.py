"""Generate native vector marks from the Electron icons. Requires reportlab."""

import base64
import re
from pathlib import Path

from reportlab import rl_config
from reportlab.graphics import renderPDF
from reportlab.graphics.shapes import Drawing
from reportlab.graphics.svgpath import SvgPath
from reportlab.lib.colors import black

rl_config.invariant = True
root = Path(__file__).resolve().parent
source = (root.parent / "web/src/components/Icons.tsx").read_text()
destination = root / "Sources/T3Native/Resources/Providers"
destination.mkdir(parents=True, exist_ok=True)

for name, driver in [
    ("OpenAI", "codex"), ("ClaudeAI", "claudeAgent"), ("CursorIcon", "cursor"),
    ("GrokIcon", "grok"), ("PiAgentIcon", "pi"), ("OpenCodeIcon", "opencode"),
]:
    component = source.split("export const " + name + ":")[1]
    component = component.split("\nexport const ")[0].split("\nconst ")[0]
    x, y, width, height = map(float, re.search(r'viewBox="([^"]+)"', component)[1].split())
    drawing = Drawing(64, 64)
    drawing.translate(-x * 64 / width, 64 + y * 64 / height)
    drawing.scale(64 / width, -64 / height)
    for attributes in re.findall(r"<path\b([^>]+?)/>", component, re.S):
        # OpenCode's interior is supplied by the row background when templated.
        if driver == "opencode" and ("data-opencode-hole" in attributes or "dark:block" in attributes):
            continue
        path = re.search(r'\bd="([^"]+)"', attributes)
        if path:
            shape = SvgPath(path[1], fillColor=black, strokeColor=None)
            shape.fillMode = 0
            drawing.add(shape)
    renderPDF.drawToFile(drawing, str(destination / (driver + ".pdf")))

data = re.search(
    r'const ANTIGRAVITY_ICON_DATA_URL\s*=\s*"data:image/png;base64,([^";]+)"', source
)[1]
(destination / "antigravity.png").write_bytes(base64.b64decode(data))
