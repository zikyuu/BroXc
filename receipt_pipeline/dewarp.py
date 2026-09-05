'''page dewarp subprocess wrapper'''
'''uses classical cubic sheet dewarping, invoked only as confidence-gated fallback'''
'''when ocr flags as low confidence read -> receipt too crumpled'''

import subprocess
from pathlib import Path 

class DewarpError(Exception):
    '''raised when dewarp subprocess fails/produces no usable output'''

def dewarp_image(image_path: str) -> str:
    """Run page-dewarp on image_path, return the path to the dewarped output image."""
    src = Path(image_path)
    if not src.exists():
        raise DewarpError(f"input image not found: {image_path}")

    result = subprocess.run(
        ["page-dewarp", str(src)],
        capture_output=True,
        text=True,
        cwd=src.parent,
    )
    if result.returncode != 0:
        raise DewarpError(f"page-dewarp failed: {result.stderr.strip()}")

    dewarped = src.parent / f"{src.stem}_thresh.png"
    if not dewarped.exists():
        raise DewarpError(
            f"page-dewarp ran but expected output not found: {dewarped}. "
            "Check your installed page-dewarp version's actual output filename."
        )

    return str(dewarped)


