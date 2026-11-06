"""Fetch pinned, digest-verified model archives; never uploads user photographs."""
from pathlib import Path
import urllib.request,hashlib,zipfile,io
root=Path(__file__).resolve().parents[1]
models=[('rawdenoise-nind','d71b5f1e727c85a359e6f74dca9e2016c9d8fc3e2f7ac3e9b347d80ceca969af','model_bayer.onnx','raw.onnx'),('denoise-nind','825b3657cbb5193a67432a2f0b44ab86531cc7337f89e8e6c17d93db9665708a','model.onnx','rgb.onnx')]
(root/'Models').mkdir(exist_ok=True)
for name,digest,member,out in models:
    data=urllib.request.urlopen(f'https://github.com/darktable-org/darktable-ai/releases/download/release-5.6.0/{name}.dtmodel',timeout=120).read()
    assert hashlib.sha256(data).hexdigest()==digest, 'Model digest mismatch'
    z=zipfile.ZipFile(io.BytesIO(data))
    (root/'Models'/out).write_bytes(z.read(f'{name}/{member}'))
    (root/'Models'/f'{name}.json').write_bytes(z.read(f'{name}/config.json'))
print('Verified both model packages')
