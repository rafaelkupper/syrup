#!/usr/bin/env python3
"""Scores results.jsonl against fixtures.json. Writes evaluated.json and summary.json."""
import json, pathlib, re, statistics, sys
HERE = pathlib.Path(__file__).resolve().parent
# An optional directory (e.g. after-quote-fix) is scored with this folder's fixture checks.
ROOT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HERE
fixtures = {f['id']: f for f in json.loads((HERE / 'fixtures.json').read_text())}

def check(text, f):
    problems = []
    text = (text or '').strip().replace('\r\n', '\n')
    has = lambda p: re.search(r'(?<!\w)' + re.escape(p) + r'(?!\w)', text, re.I) is not None
    for group in f['required']:
        if not any(has(v) for v in group): problems.append('missing ' + '/'.join(group))
    for phrase in f['forbidden']:
        if has(phrase): problems.append('kept ' + phrase)
    if re.match(r"^(?:here is|here's|translation:|output:|sure[,!])", text, re.I): problems.append('preamble')
    layout = f['layout']
    if layout == 'line' and (text.count('\n') != 1 or '\n\n' in text): problems.append('expected one line break')
    if layout == 'paragraph' and (text.count('\n') != 2 or '\n\n' not in text): problems.append('expected one blank line')
    if layout == 'single' and '\n' in text: problems.append('unexpected line break')
    if layout == 'quote' and not any(text.startswith(a) and text.endswith(b) for a, b in [('"', '"'), ('“', '”'), ("'", "'")]): problems.append('missing quotes')
    if layout == 'bullets' and len(re.findall(r'^\s*[-*•]\s+\S', text, re.M)) != 3: problems.append('expected three bullets')
    if layout == 'numbered' and len(re.findall(r'^\s*\d+[.)]\s+\S', text, re.M)) != 3: problems.append('expected three numbered items')
    return problems

def feature(fid):
    f = fixtures[fid]
    if f['feature'] == 'formatting' and f['layout'] == 'quote': return 'quotes'
    return f['feature']

rows = []
for line in (ROOT / 'results.jsonl').read_text().splitlines():
    r = json.loads(line)
    f = fixtures[r['id']]
    ok = r['status'] == 'completed'
    r['feature'] = feature(r['id'])
    r['delivered_failures'] = check(r.get('output'), f) if ok else ['request error']
    r['raw_failures'] = check(r.get('raw_output'), f) if ok else ['request error']
    rows.append(r)
(ROOT / 'evaluated.json').write_text(json.dumps(rows, ensure_ascii=False, indent=1) + '\n')

order = ['plain', 'self-correction', 'formatting', 'quotes', 'literal']
summary = {}
for model in dict.fromkeys(r['model'] for r in rows):
    g = [r for r in rows if r['model'] == model]
    lat = sorted(r['duration_ms'] for r in g if r['status'] == 'completed')
    s = {'requests': len(g), 'completed': sum(r['status'] == 'completed' for r in g),
         'latency_ms': {'median': statistics.median(lat), 'p90': lat[int(0.9 * (len(lat) - 1))], 'max': lat[-1]},
         'features': {}}
    for feat in order:
        fg = [r for r in g if r['feature'] == feat]
        s['features'][feat] = {'total': len(fg), 'raw_pass': sum(not r['raw_failures'] for r in fg),
                               'delivered_pass': sum(not r['delivered_failures'] for r in fg)}
    s['delivered_pass'] = sum(not r['delivered_failures'] for r in g)
    s['raw_pass'] = sum(not r['raw_failures'] for r in g)
    summary[model] = s
(ROOT / 'summary.json').write_text(json.dumps(summary, indent=1) + '\n')

for model, s in summary.items():
    print(f"\n== {model}: {s['completed']}/{s['requests']} completed; delivered {s['delivered_pass']}/{s['requests']}, raw {s['raw_pass']}/{s['requests']}; "
          f"latency median {s['latency_ms']['median']} ms, p90 {s['latency_ms']['p90']} ms, max {s['latency_ms']['max']} ms")
    for feat, v in s['features'].items():
        print(f"   {feat:16} raw {v['raw_pass']:>2}/{v['total']}  delivered {v['delivered_pass']:>2}/{v['total']}")
    for r in rows:
        if r['model'] == model and r['raw_failures']:
            print('   RAW FAIL', r['key'], r['raw_failures'], repr(r.get('raw_output', r.get('error')))[:160])
