"""Convert a user-supplied LCP directory; generated data stays local (not in Git)."""
import argparse, hashlib, json, math
from pathlib import Path
import xml.etree.ElementTree as ET

def name(tag): return tag.split('}')[-1]
def fields(node):
    result={name(k):v for k,v in node.attrib.items()}
    for child in node:
        if name(child.tag)=='Description': result.update(fields(child))
        elif len(child)==0 and child.text and child.text.strip(): result[name(child.tag)]=child.text.strip()
    return result
def model(node):
    values=fields(node); result={}
    for k,v in values.items():
        try:
            number=float(v)
            if math.isfinite(number): result[k]=number
        except ValueError: pass
    return result
def convert(path):
    root=ET.parse(path).getroot()
    descriptions=[e for e in root.iter() if name(e.tag)=='li' and 'FocalLength' in fields(e)]
    records=[]; header={}
    for e in descriptions:
        f=fields(e)
        if not f.get('Lens'): f['Lens']=f.get('LensPrettyName','')
        if not f['Lens']: continue
        header=f
        entry={'focal':float(f['FocalLength']), 'distance':float(f.get('FocusDistance',10000)), 'av':float(f.get('ApertureValue',0))}
        for tag,key in [('PerspectiveModel','distortion'),('FisheyeModel','fisheye'),('VignetteModel','vignette'),('ChromaticGreenModel','green'),('ChromaticRedGreenModel','red'),('ChromaticBlueGreenModel','blue')]:
            node=next((n for n in e.iter() if name(n.tag)==tag),None)
            if node is not None: entry[key]=model(node)
        piece=next((n for n in e.iter() if name(n.tag)=='VignetteModelPiecewiseParam'),None)
        if piece is not None: entry['piecewise']=[list(map(float,n.text.split(','))) for n in piece.iter() if name(n.tag)=='li' and n.text]
        records.append(entry)
    if not records: raise ValueError(f'No calibration records: {path.name}')
    return {'name':header['Lens'],'camera':header.get('Model',''),'raw':header.get('CameraRawProfile','True').lower()=='true','crop':float(header.get('SensorFormatFactor',1)), 'records':records,'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
def main():
    p=argparse.ArgumentParser();p.add_argument('directory',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    profiles=[convert(path) for path in sorted(a.directory.rglob('*.lcp'))]
    data={'schema':1,'profiles':profiles}
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(data,separators=(',',':'),ensure_ascii=False),encoding='utf-8')
    print(json.dumps({'profiles':len(profiles),'raw':sum(p['raw'] for p in profiles),'records':sum(len(p['records']) for p in profiles),'bytes':a.output.stat().st_size}))
if __name__=='__main__':main()
