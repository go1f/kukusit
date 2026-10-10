"""Collect original distribution license files for the frozen runtime."""
from importlib import metadata
from pathlib import Path
import shutil
import sys

destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
for distribution in metadata.distributions():
    name = distribution.metadata.get('Name', 'unknown')
    for file in distribution.files or []:
        if any(word in str(file).lower() for word in ('license', 'copying', 'notice', 'copyright')):
            source = Path(distribution.locate_file(file))
            if source.is_file() and '.dist-info' in str(file):
                relative = Path(*Path(str(file)).parts[1:])
                target = destination / name / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
