import sys
from pathlib import Path

# minion.py is a single file at the repository root, installed as-is; import it from there.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
