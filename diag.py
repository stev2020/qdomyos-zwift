import json, time, urllib.request, urllib.error

APP_UA = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36 FunRun'
KEEP = ('server', 'x-vercel-mitigated', 'cf-mitigated', 'retry-after', 'content-type', 'cf-ray')

def get(url, data=None, ctype=None):
    h = {'User-Agent': APP_UA}
    if ctype: h['Content-Type'] = ctype
    req = urllib.request.Request(url, data=data, headers=h)
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, dict(r.headers), r.read(400000), time.time() - t
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read(), time.time() - t
    except Exception as e:
        return 0, {}, str(e).encode(), time.time() - t

def show(tag, res, snippet=0):
    st, h, b, dt = res
    keep = {k.lower(): v for k, v in h.items() if k.lower() in KEEP}
    s = b[:200000].decode('utf-8', 'replace')
    i = s.find('<title>')
    title = s[i + 7:s.find('</title>', i)].strip() if i >= 0 else ''
    print(f'{tag}: {st} {dt:.2f}s {len(b)}B {keep} {title!r}', flush=True)
    if snippet:
        print('   ', s[:snippet].replace('\n', ' '), flush=True)
    return s

show('tl page', get('https://trackleaders.com/highland25'))
show('tl route', get('https://trackleaders.com/spot/highland25/route.js'), 160)
home = show('tl home', get('https://trackleaders.com/'))
links = []
k = 0
while True:
    k = home.find('href="', k)
    if k < 0: break
    e = home.find('"', k + 6)
    links.append(home[k + 6:e]); k = e
print('tl home links', len(links), links[:80])
show('fmc page', get('https://www.followmychallenge.com/live/bm25/'))
show('fmc live index', get('https://www.followmychallenge.com/live/'), 300)
show('fmc home', get('https://www.followmychallenge.com/'), 300)
show('fmc tprno6', get('https://live.followmychallenge.com/tprno6/'))
show('madcap geo', get('https://api2.madcap.cc/event/geo/v6', json.dumps({'event': 'lakes-n-knodel-26'}).encode(), 'application/json'), 160)
show('madcap app', get('https://app.madcap.cc/'), 200)
show('rwgps', get('https://ridewithgps.com/routes/55605184.json'), 120)
show('dotwatcher robots', get('https://dotwatcher.cc/robots.txt'), 300)
