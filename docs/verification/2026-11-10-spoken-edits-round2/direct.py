import json,sys,time,urllib.request,pathlib,concurrent.futures as cf,statistics
root=pathlib.Path(sys.argv[1]); prompt=pathlib.Path(sys.argv[2]).read_text(); out=pathlib.Path(sys.argv[3])
key=[l.split('=',1)[1].strip() for l in (root/'.env').read_text().splitlines() if l.startswith('CEREBRAS_API_KEY=')][-1]
fx={f["id"]:f for f in json.loads(pathlib.Path(sys.argv[8]).read_text())} if len(sys.argv)>8 else {f["id"]:f for f in json.loads((root/"docs/verification/2026-11-10-spoken-edits-round2/fixtures.json").read_text())}
ids=sys.argv[5].split(','); reps=int(sys.argv[6]); model=sys.argv[4]
def call(effort,fid,rep):
    temp=0.3
    if effort.startswith('t'): temp=float(effort[1:]);
    body={"model":model,"temperature":temp,"messages":[{"role":"system","content":prompt},{"role":"user","content":fx[fid]['input']}]}
    if effort!='default' and not effort.startswith('t'): body["reasoning_effort"]=effort
    req=urllib.request.Request("https://api.cerebras.ai/v1/chat/completions",data=json.dumps(body).encode(),headers={"Authorization":"Bearer "+key,"Content-Type":"application/json","User-Agent":"syrup-eval"})
    t=time.time()
    for attempt in range(4):
        try:
            d=json.load(urllib.request.urlopen(req,timeout=60)); break
        except Exception as e:
            err=str(e); time.sleep(2+attempt*3); d=None
    if d is None: return {"key":f"{model}@{effort}/{rep}/{fid}","model":f"{model}@{effort}","id":fid,"repetition":rep,"status":"error","error":err,"duration_ms":0}
    c=d['choices'][0]; raw=c['message'].get('content') or ''
    return {"key":f"{model}@{effort}/{rep}/{fid}","model":f"{model}@{effort}","id":fid,"repetition":rep,"status":"completed","raw_output":raw,"output":raw.strip(),"finish_reason":c.get('finish_reason'),"usage":d.get('usage'),"duration_ms":int((time.time()-t)*1000)}
jobs=[(e,i,r) for e in sys.argv[7].split(',') for r in range(1,reps+1) for i in ids]
with cf.ThreadPoolExecutor(3) as ex: rows=list(ex.map(lambda j: call(*j),jobs))
out.parent.mkdir(parents=True,exist_ok=True)
with out.open('a') as f:
    for r in rows: f.write(json.dumps(r,ensure_ascii=False)+'\n')
print(len(rows),'rows', sum(r['status']!='completed' for r in rows),'errors')
