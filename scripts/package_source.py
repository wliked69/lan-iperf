"""Package portable project sources, excluding local build caches."""
from pathlib import Path
import os
import zipfile

root = Path(__file__).resolve().parent.parent
excluded_dirs = {'.tools', 'dist', 'build', '.git', '.gradle', '.dart_tool',
                 '.idea', '.cxx', 'ephemeral'}
excluded_files = {'local.properties', '.flutter-plugins-dependencies'}
output = root / 'dist' / 'lan-iperf-source.zip'
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for directory, directories, filenames in os.walk(root):
        directories[:] = sorted(d for d in directories if d not in excluded_dirs)
        for filename in sorted(filenames):
            path = Path(directory) / filename
            if path.is_symlink() or path.name in excluded_files:
                continue
            if path.suffix in {'.iml', '.jks', '.log'}:
                continue
            archive.write(path, 'lan-iperf/' + path.relative_to(root).as_posix())
print(output)
