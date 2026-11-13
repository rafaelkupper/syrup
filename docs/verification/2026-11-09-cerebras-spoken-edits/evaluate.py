#!/usr/bin/env python3
import collections,json,pathlib,re
ROOT=pathlib.Path(__file__).resolve().parent
fixtures={x['id']:x for x in json.loads((ROOT/'fixtures.json').read_text())}
def check(text,f):
    problems=[]
    text=text.strip().replace('\r\n','\n')
    def has(phrase):
        return re.search(r'(?<!\w)'+re.escape(phrase)+r'(?!\w)',text,re.I) is not None
    for group in f['required']:
        if not any(has(v) for v in group):problems.append('missing '+'/'.join(group))
    for phrase in f['forbidden']:
        if has(phrase):problems.append('retained '+phrase)
    if re.match(r'^(?:here is|here\x27s|translation:|output:|sure[,!])',text,re.I):problems.append('preamble')
    layout=f['layout']
    if layout=='line' and (text.count('\n')!=1 or '\n\n' in text):problems.append('expected one line break')
    if layout=='paragraph' and (text.count('\n')!=2 or '\n\n' not in text):problems.append('expected one blank line')
    if layout=='single' and '\n' in text:problems.append('unexpected line break')
    if layout=='quote' and not any(text.startswith(a) and text.endswith(b) for a,b in [('"','"'),('“','”'),("'","'")]):problems.append('missing enclosing quotes')
    if layout=='bullets' and len(re.findall(r'^\s*[-*•]\s+\S',text,re.M))!=3:problems.append('expected three bullets')
    if layout=='numbered' and len(re.findall(r'^\s*\d+[.)]\s+\S',text,re.M))!=3:problems.append('expected three numbered items')
    return problems
rows=[]
for line in (ROOT/'results.jsonl').read_text().splitlines():
    r=json.loads(line); f=fixtures[r['id']]
    r['delivered_failures']=check(r.get('output',''),f) if r['status']=='completed' else ['request error']
    if r['mode']=='layout':r['raw_failures']=None
    else:r['raw_failures']=check(r.get('raw_output',''),f) if r['status']=='completed' else ['request error']
    rows.append(r)
(ROOT/'evaluated.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
for mode in dict.fromkeys(r['mode'] for r in rows):
    group=[r for r in rows if r['mode']==mode]
    complete=sum(r['status']=='completed' for r in group)
    passed=sum(not r['delivered_failures'] for r in group)
    print(f'{mode}: {complete}/{len(group)} requests completed; {passed}/{len(group)} delivered outputs met fixture checks')
    for r in group:
        if r['delivered_failures']:
            print(r['key'],'FAIL',r['delivered_failures'],'raw failures',r['raw_failures'],'output',repr(r.get('output',r.get('error'))))
